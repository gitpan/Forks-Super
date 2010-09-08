#
# Forks::Super::Job - object representing a task to perform in
#                     a background process
# See the subpackages for some implementation details
#

package Forks::Super::Job;
use Forks::Super::Debug qw(debug);
use Forks::Super::Util qw(is_number qualify_sub_name IS_WIN32 is_pipe);
use Forks::Super::Config qw(:all);
use Forks::Super::Job::Ipc;   # does windows prefer to load Ipc before Timeout?
use Forks::Super::Job::Timeout;
use Forks::Super::Queue qw(queue_job);
use Forks::Super::Job::OS;
use Forks::Super::Job::Callback qw(run_callback);
use base 'Exporter';
use Carp;
use IO::Handle;
use strict;
use warnings;

our @EXPORT = qw(@ALL_JOBS %ALL_JOBS);
our $VERSION = '0.38';

our (@ALL_JOBS, %ALL_JOBS, $WIN32_PROC, $WIN32_PROC_PID);
our $OVERLOAD_ENABLED = 0;
our $INSIDE_END_QUEUE = 0;

enable_overload() if $ENV{"FORKS_SUPER_JOB_OVERLOAD"};

#############################################################################
# Object methods (meant to be called as $job->xxx(@args))

sub new {
  my ($class, $opts) = @_;
  my $this = {};
  if (ref $opts eq 'HASH') {
    $this->{$_} = $opts->{$_} foreach keys %$opts;
  }
  $this->{created} = Time::HiRes::gettimeofday();
  $this->{state} = 'NEW';
  $this->{ppid} = $$;
  if (!defined $this->{_is_bg}) {
    $this->{_is_bg} = 0;
  }
  if (!defined $this->{debug}) {
    $this->{debug} = $Forks::Super::Debug::DEBUG;
  }
  push @ALL_JOBS, $this;
  bless $this, 'Forks::Super::Job';
  if ($this->{debug}) {
    debug("New job created: ", $this->toString());
  }
  return $this;
}

sub is_complete {
  my $job = shift;
  return defined $job->{state} &&
    ($job->{state} eq 'COMPLETE' || $job->{state} eq 'REAPED');
}

sub is_started {
  my $job = shift;
  return $job->is_complete || $job->is_active || 
    (defined $job->{state} && $job->{state} eq 'SUSPENDED');
}

sub is_active {
  my $job = shift;
  return defined $job->{state} && $job->{state} eq 'ACTIVE';
}

sub is_suspended {
  my $job = shift;
  return defined $job->{state} && $job->{state} =~ /SUSPENDED/;
}

sub is_deferred {
  my $job = shift;
  return defined $job->{state} && $job->{state} =~ /DEFERRED/;
}

sub waitpid {
  my ($job, $flags, $timeout) = @_;
  return Forks::Super::Wait::waitpid($job->{pid}, $flags, $timeout || 0);
}

sub wait {
  my ($job, $timeout) = @_;
  return Forks::Super::Wait::waitpid($job->{pid}, 0, $timeout || 0);
}

sub kill {
  my ($job, $signal) = @_;
  return Forks::Super::kill($signal || Forks::Super::Util::signal_number('INT') || 1, $job);
}

sub state {
  my $job = shift;
  return $job->{state};
}

sub status {
  my $job = shift;
  return $job->{status};  # may be undefined
}

#
# Produces string representation of a Forks::Super::Job object.
#
sub toString {
  my $job = shift;
  my @to_display = qw(pid state create);
  foreach my $attr (qw(real_pid style cmd exec sub args start end reaped
		       status closure pgid child_fh queue_priority)) {
    push @to_display, $attr if defined $job->{$attr};
  }
  my @output = ();
  foreach my $attr (@to_display) {
    next unless defined $job->{$attr};
    if (ref $job->{$attr} eq 'ARRAY') {
      push @output, "$attr=[" . join(q{,},@{$job->{$attr}}) . ']';
    } else {
      push @output, "$attr=" . $job->{$attr};
    }
  }
  return '{' . join ( ';' , @output), '}';
}

sub toShortString {
  my $job = shift;
  if (defined $job->{short_string}) {
    return $job->{short_string};
  }
  my @to_display = ();
  foreach my $attr (qw(pid state cmd exec sub args closure real_pid)) {
    push @to_display, $attr if defined $job->{$attr};
  }
  my @output;
  foreach my $attr (@to_display) {
    if (ref $job->{$attr} eq 'ARRAY') {
      push @output, "$attr=[" . join(",", @{$job->{$attr}}) . "]";
    } else {
      push @output, "$attr=" . $job->{$attr};
    }
  }
  return $job->{short_string} = "{" . join(";",@output) . "}";
}

sub _mark_complete {
  my $job = shift;
  $job->{state} = 'COMPLETE';
  $job->{end} = Time::HiRes::gettimeofday();

  $job->run_callback('collect');
  $job->run_callback('finish');
}

sub _mark_reaped {
  my $job = shift;
  $job->{state} = 'REAPED';
  $job->{reaped} = Time::HiRes::gettimeofday();
  $? = $job->{status};
  debug("Job $job->{pid} reaped") if $job->{debug};
  return;
}

#
# determine whether a job is eligible to start
#
sub can_launch {
  no strict 'refs';

  my $job = shift;
  $job->{last_check} = Time::HiRes::gettimeofday();
  if (defined $job->{can_launch}) {
    if (ref $job->{can_launch} eq 'CODE') {
      return $job->{can_launch}->($job);
    } elsif (ref $job->{can_launch} eq '') {
      #no strict 'refs';
      my $can_launch_sub = $job->{can_launch};
      return $can_launch_sub->($job);
    }
  } else {
    return $job->_can_launch;
  }
}

sub _can_launch_delayed_start_check {
  my $job = shift;
  return 1 if !defined $job->{start_after} ||
    Time::HiRes::gettimeofday() >= $job->{start_after};

  debug('Forks::Super::Job::_can_launch(): ',
	'start delay requested. launch fail') if $job->{debug};

  # delay option should normally be associated with queue on busy behavior.
  # any reason not to make this the default ?
  #  delay + fail   is pretty dumb
  #  delay + block  is like sleep + fork

  $job->{_on_busy} = 'QUEUE' if not defined $job->{on_busy};
  #$job->{_on_busy} = 'QUEUE' if not defined $job->{_on_busy};
  return 0;
}

sub _can_launch_dependency_check {
  my $job = shift;
  my @dep_on = defined $job->{depend_on} ? @{$job->{depend_on}} : ();
  my @dep_start = defined $job->{depend_start} ? @{$job->{depend_start}} : ();

  foreach my $dj (@dep_on) {
    my $j = $ALL_JOBS{$dj};
    if (not defined $j) {
      carp "Forks::Super::Job: ",
	"dependency $dj for job $job->{pid} is invalid. Ignoring.\n";
      next;
    }
    unless ($j->is_complete) {
      debug('Forks::Super::Job::_can_launch(): ',
	"job waiting for job $j->{pid} to finish. launch fail.")
	if $j->{debug};
      return 0;
    }
  }

  foreach my $dj (@dep_start) {
    my $j = $ALL_JOBS{$dj};
    if (not defined $j) {
      carp "Forks::Super::Job ",
	"start dependency $dj for job $job->{pid} is invalid. Ignoring.\n";
      next;
    }
    unless ($j->is_started) {
      debug('Forks::Super::Job::_can_launch(): ',
	"job waiting for job $j->{pid} to start. launch fail.")
	if $j->{debug};
      return 0;
    }
  }
  return 1;
}

#
# default function for determining whether the system
# is too busy to create a new child process or not
#
sub _can_launch {
  no warnings qw(once);

  my $job = shift;
  my $max_proc = defined $job->{max_proc}
    ? $job->{max_proc} : $Forks::Super::MAX_PROC;
  my $max_load = defined $job->{max_load}
    ? $job->{max_load} : $Forks::Super::MAX_LOAD;
  my $force = defined $job->{max_load} && $job->{force};

  if ($force) {
    debug('Forks::Super::Job::_can_launch(): force attr set. launch ok')
      if $job->{debug};
    return 1;
  }

  return 0 if not $job->_can_launch_delayed_start_check;
  return 0 if not $job->_can_launch_dependency_check;

  if ($max_proc > 0) {
    my $num_active = count_active_processes();
    if ($num_active >= $max_proc) {
      debug('Forks::Super::Job::_can_launch(): ',
	"active jobs $num_active exceeds limit $max_proc. ",
	    'launch fail.') if $job->{debug};
      return 0;
    }
  }

  if ($max_load > 0) {
    my $load = get_cpu_load();
    if ($load > $max_load) {
      debug('Forks::Super::Job::_can_launch(): ',
	"cpu load $load exceeds limit $max_load. launch fail.")
	if $job->{debug};
      return 0;
    }
  }

  debug('Forks::Super::Job::_can_launch(): system not busy. launch ok.')
    if $job->{debug};
  return 1;
}

# Perl system fork() call. Encapsulated here so it can be overridden 
# and mocked for testing. See t/17-retries.t
sub _CORE_fork { CORE::fork }

#
# make a system fork call and configure the job object
# in the parent and the child processes
#
sub launch {
  my $job = shift;
  if ($job->is_started) {
    Carp::confess "Forks::Super::Job::launch() ",
	"called on a job in state $job->{state}!\n";
  }

  if ($$ != $Forks::Super::MAIN_PID && $Forks::Super::CHILD_FORK_OK > 0) {
    $Forks::Super::MAIN_PID = $$;
    $Forks::Super::CHILD_FORK_OK--;
  }

  if ($$ != $Forks::Super::MAIN_PID && $Forks::Super::CHILD_FORK_OK < 1) {
    return _launch_from_child($job);
  }
  $job->_preconfig_fh;
  $job->_preconfig2;





  my $retries = $job->{retries} || 0;

  my $pid = _CORE_fork();
  while (!defined $pid && $retries-- > 0) {
    warn "Forks::Super::launch: ",
      "system fork call returned undef. Retrying ...\n";
    $Forks::Super::Job::_RETRY_PAUSE ||= 1.0;
    my $delay = 1.0 + $Forks::Super::Job::_RETRY_PAUSE
      * (($job->{retries} || 1) - $retries);
    Forks::Super::Util::pause($delay);
    $pid = _CORE_fork();
  }







  if (!defined $pid) {
    debug('Forks::Super::Job::launch(): CORE::fork() returned undefined!')
      if $job->{debug};
    return;
  }


  if (Forks::Super::Util::isValidPid($pid)) { # parent
    $ALL_JOBS{$pid} = $job;
    if (defined $job->{state} &&
	$job->{state} ne 'NEW' &&
	$job->{state} ne 'LAUNCHING' &&
	$job->{state} ne 'DEFERRED') {
      warn "Forks::Super::Job::launch(): ",
	"job $pid already has state: $job->{state}\n";
    } else {
      $job->{state} = 'ACTIVE';

      #
      # it is possible that this child exited quickly and has already
      # been reaped in the SIGCHLD handler. In that case, the signal
      # handler should have made an entry in %Forks::Super::BASTARD_DATA
      # for this process.
      #
      if (defined $Forks::Super::BASTARD_DATA{$pid}) {
	warn "Forks::Super::Job::launch: ",
	  "Job $pid reaped before parent initialization.\n";
	$job->_mark_complete;
	($job->{end}, $job->{status})
	  = @{delete $Forks::Super::BASTARD_DATA{$pid}};
      }
    }
    $job->{real_pid} = $pid;
    $job->{pid} = $pid unless defined $job->{pid};
    $job->{start} = Time::HiRes::gettimeofday();

    $job->_config_parent;
    $job->run_callback('start');
    Forks::Super::Sigchld::handle_CHLD(-1);

    if ($OVERLOAD_ENABLED) {
      if ($Forks::Super::SUPPORT_LIST_CONTEXT && wantarray) {
	return ($job,$job);
      } else {
	return $job;
      }
    } elsif ($Forks::Super::SUPPORT_LIST_CONTEXT && wantarray) {
      return ($pid,$job);
    } else {
      return $pid;
    }
  } elsif ($pid != 0) {
    Carp::confess "Forks::Super::launch(): ",
	"Somehow we got pid=$pid from fork call.";
  }

  # child
  Forks::Super::init_child() if defined &Forks::Super::init_child;
  $job->_config_child;
  if ($job->{style} eq 'cmd') {

    debug("Executing [ @{$job->{cmd}} ]") if $job->{debug};
    my $c1;
    if (&IS_WIN32) {
      local $ENV{_FORK_PPID} = $$;
      local $ENV{_FORK_PID} = $$;

      # There are lots of ways to spawn a process in Windows
      if (1 && Forks::Super::Config::CONFIG('Win32::Process')) {
	$c1 = Forks::Super::Job::OS::Win32::open_win32_process($job);
      } elsif (1 && Forks::Super::Config::CONFIG('Win32::Process')) {
	$c1 = Forks::Super::Job::OS::Win32::open2_win32_process($job);
      } elsif (1) {
	$c1 = Forks::Super::Job::OS::Win32::open3_win32_process($job);
      } elsif (0 && Forks::Super::Config::CONFIG('Win32::Process')) {
	$c1 = Forks::Super::Job::OS::Win32::create_win32_process($job);
      } else {
	$c1 = Forks::Super::Job::OS::Win32::system_win32_process($job);
      }
    } else {
      $c1 = system( @{$job->{cmd}} );
    }
    debug("Exit code of $$ was $c1") if $job->{debug};
    deinit_child();
    exit $c1 >> 8;
  } elsif ($job->{style} eq 'exec') {
    local $ENV{_FORK_PPID} = $$;
    local $ENV{_FORK_PID} = $$;
    debug("Exec'ing [ @{$job->{exec}} ]") if $job->{debug};
    exec( @{$job->{exec}} );
  } elsif ($job->{style} eq 'sub') {
    no strict 'refs';
    $job->{sub}->(@{$job->{args}});
    debug("Job $$ subroutine call has completed") if $job->{debug};
    deinit_child();
    exit 0;
  }
  return $Forks::Super::SUPPORT_LIST_CONTEXT && wantarray ? (0) : 0;
}

sub _launch_from_child {
  my $job = shift;
  if ($Forks::Super::CHILD_FORK_OK == 0) {
    carp 'Forks::Super::Job::launch(): fork() not allowed ',
      "in child process $$ while \$Forks::Super::CHILD_FORK_OK ",
	"is not set!\n";

    return;
  } elsif ($Forks::Super::CHILD_FORK_OK == -1) {
    carp "Forks::Super::Job::launch(): Forks::Super::fork() ",
      "call not allowed\n",
	"in child process $$ while \$Forks::Super::CHILD_FORK_OK <= 0.\n",
	  "Will create child of child with CORE::fork()\n";

    my $pid = _CORE_fork();
    if (defined $pid && $pid == 0) {
      # child of child
      if (defined &Forks::Super::init_child) {
	Forks::Super::init_child();
      } else {
	init_child();
      }
      return $Forks::Super::SUPPORT_LIST_CONTEXT && wantarray ? ($pid) : $pid;
    }
    return $Forks::Super::SUPPORT_LIST_CONTEXT && wantarray ? ($pid) : $pid;
  }
  return;
}

sub suspend {
  my $j = shift;
  $j = Forks::Super::Job::get($j) if ref $j ne 'Forks::Super::Job';
  my $pid = $j->{real_pid};
  if ($j->{state} eq 'ACTIVE') {
    local $! = 0;
    my $kill_result = Forks::Super::kill('STOP', $j);
    if ($kill_result > 0) {
      $j->{state} = 'SUSPENDED';
      return 1;
    }
    carp "'STOP' signal not received by $pid, job ", $j->toString(), "\n";
    return;
  }
  if ($j->{state} eq 'DEFERRED') {
    $j->{state} = 'SUSPENDED-DEFERRED';
    return -1;
  }
  if ($j->is_complete) {
    carp "Forks::Super::Job::suspend(): called on completed job ", 
      $j->{pid}, "\n";
    return;
  }
  if ($j->{state} eq 'SUSPENDED') {
    carp "Forks::Super::Job::suspend(): called on suspended job ", 
      $j->{pid}, "\n";
    return;
  }
  carp "Forks::Super::Job::suspend(): called on job ", $j->toString(), "\n";
  return;
}

sub resume {
  my $j = shift;
  $j = Forks::Super::Job::get($j) if ref $j ne 'Forks::Super::Job';
  my $pid = $j->{real_pid};
  if ($j->{state} eq 'SUSPENDED') {
    local $! = 0;
    my $kill_result = Forks::Super::kill('CONT', $j);
    if ($kill_result > 0) {
      $j->{state} = 'ACTIVE';
      return 1;
    }
    carp "'CONT' signal not received by $pid, job ", $j->toString(), "\n";
    return;
  }
  if ($j->{state} eq 'SUSPENDED-DEFERRED') {
    $j->{state} = 'DEFERRED';
    return -1;
  }
  if ($j->is_complete) {
    carp "Forks::Super::Job::resume(): called on a completed job ", 
      $j->{pid}, "\n";
    return;
  }
  carp "Forks::Super::Job::resume(): called on job in state ", 
    $j->{state}, "\n";
  return;
}

#
# do further initialization of a Forks::Super::Job object,
# mainly setting derived fields
#
sub _preconfig {
  my $job = shift;

  $job->_preconfig_style;
  $job->_preconfig_busy_action;
  $job->_preconfig_start_time;
  $job->_preconfig_dependencies;
  Forks::Super::Job::Callback::_preconfig_callbacks($job);
  Forks::Super::Job::OS::_preconfig_os($job);
  return;
}

# some final initialization just before launch
sub _preconfig2 {
  my $job = shift;
  if (!defined $job->{debug}) {
    $job->{debug} = $Forks::Super::Debug::DEBUG;
  }
}

sub _preconfig_style {
  my $job = shift;

  ###################
  # set up style.
  #
  if (defined $job->{cmd}) {
    if (ref $job->{cmd} ne 'ARRAY') {
      $job->{cmd} = [ $job->{cmd} ];
    }
    $job->{style} = 'cmd';
  } elsif (defined $job->{exec}) {
    if (ref $job->{exec} ne 'ARRAY') {
      $job->{exec} = [ $job->{exec} ];
    }
    $job->{style} = 'exec';
  } elsif (defined $job->{sub}) {
    $job->{style} = 'sub';
    $job->{sub} = qualify_sub_name $job->{sub};
    if (defined $job->{args}) {
      if (ref $job->{args} ne 'ARRAY') {
	$job->{args} = [ $job->{args} ];
      }
    } else {
      $job->{args} = [];
    }
  } else {
    $job->{style} = 'natural';
  }
  return;
}

sub _preconfig_busy_action {
  my $job = shift;

  ######################
  # what will we do if the job cannot launch?
  #
  if (defined $job->{on_busy}) {
    $job->{_on_busy} = $job->{on_busy};
  } else {
    no warnings 'once';
    $job->{_on_busy} = $Forks::Super::ON_BUSY || 'block';
  }
  $job->{_on_busy} = uc $job->{_on_busy};

  ########################
  # make a queue priority available if needed
  #
  if (not defined $job->{queue_priority}) {
    $job->{queue_priority} = Forks::Super::Queue::get_default_priority();
  }
  return;
}

sub _preconfig_start_time {
  my $job = shift;

  ###########################
  # configure a future start time
  my $start_after = 0;
  if (defined $job->{delay}) {
    $start_after = Time::HiRes::gettimeofday() +  Forks::Super::Job::Timeout::_time_from_natural_language($job->{delay}, 1);
    #$start_after = Time::HiRes::gettimeofday() +  $job->{delay};
  }
  if (defined $job->{start_after}) {
    my $start_after2 = Forks::Super::Job::Timeout::_time_from_natural_language($job->{start_after}, 0);
    #my $start_after2 = $job->{start_after};
    $start_after = $start_after2 if $start_after < $start_after2;
  }
  if ($start_after) {
    $job->{start_after} = $start_after;
    delete $job->{delay};
    debug('Forks::Super::Job::_can_launch(): start delay requested.')
      if $job->{debug};
  }
  return;
}

sub _preconfig_dependencies {
  my $job = shift;

  ##########################
  # assert dependencies are expressed as array refs
  # expand job names to pids
  #
  if (defined $job->{depend_on}) {
    if (ref $job->{depend_on} ne 'ARRAY') {
      $job->{depend_on} = [ $job->{depend_on} ];
    }
    $job->{depend_on} = _resolve_names($job, $job->{depend_on});
  }
  if (defined $job->{depend_start}) {
    if (ref $job->{depend_start} ne 'ARRAY') {
      $job->{depend_start} = [ $job->{depend_start} ];
    }
    $job->{depend_start} = _resolve_names($job, $job->{depend_start});
  }
  return;
}

# convert job names in an array to job ids, if necessary
sub _resolve_names {
  my $job = shift;
  my @in = @{$_[0]};
  my @out = ();
  foreach my $id (@in) {
    if (ref $id eq 'Forks::Super::Job') {
      push @out, $id;
    } elsif (is_number($id) && defined $ALL_JOBS{$id}) {
      push @out, $id;
    } else {
      my @j = Forks::Super::Job::getByName($id);
      if (@j > 0) {
	foreach my $j (@j) {
	  next if \$j eq \$job; 
	  # $j eq $job was not sufficient when $job is overloaded
	  # and $job->{pid} has not been set.

	  push @out, $j->{pid};
	}
      } else {
	carp "Forks::Super: Job ",
	  "dependency identifier \"$id\" is invaild. Ignoring\n";
      }
    }
  }
  return [ @out ];
}

#
# set some additional attributes of a Forks::Super::Job after the
# child is successfully launched.
#
sub _config_parent {
  my $job = shift;
  $job->_config_fh_parent;
  if (Forks::Super::Config::CONFIG('getpgrp')) {
    $job->{pgid} = getpgrp($job->{real_pid});

    # when  timeout =>   or   expiration =>  is used,
    # PGID of child will be set to child PID
    # XXX - tragically this is not always true. Do the parent settings matter
    #       though? Should comment out these lines and test
    if (defined $job->{timeout} or defined $job->{expiration}) {
      $job->{pgid} = $job->{real_pid};
    }
  }
  return;
}

sub _config_child {
  my $job = shift;
  $Forks::Super::Job::self = $job;
  $job->_config_callback_child;
  $job->_config_debug_child;
  $job->_config_timeout_child;
  $job->_config_os_child;
  $job->_config_fh_child;
  return;
}

sub _config_debug_child {
  my $job = shift;
  if ($job->{debug} && $job->{undebug}) {
    if (Forks::Super::_is_test()) {
      debug("Disabling debugging in child $job->{pid}");
    }
    $Forks::Super::Debug::DEBUG = 0;
    $job->{debug} = 0;
  }
}

END {
  $INSIDE_END_QUEUE = 1;
  if ($$ == ($Forks::Super::MAIN_PID ||= $$)) {

    # disable SIGCHLD handler during cleanup. Hopefully this will fix
    # intermittent test failures where all subtests pass but the
    # test exits with non-zero exit status (e.g., t/42d-filehandles.t)
    delete $SIG{CHLD};

    Forks::Super::Queue::_cleanup();
    Forks::Super::Job::Ipc::_cleanup();
  } else {
    Forks::Super::Job::Timeout::_cleanup_child();
  }
}

#############################################################################
# Package methods (meant to be called as Forks::Super::Job::xxx(@args))

sub enable_overload {
  if (!$OVERLOAD_ENABLED) {
    $OVERLOAD_ENABLED = 1;

    eval <<'__enable_overload__';
    use overload
      '""' => sub { $_[0]->{pid} },
      '+' => sub { $_[0]->{pid} + $_[1] },
      '*' => sub { $_[0]->{pid} * $_[1] },
      '&' => sub { $_[0]->{pid} & $_[1] },
      '|' => sub { $_[0]->{pid} | $_[1] },
      '^' => sub { $_[0]->{pid} ^ $_[1] },
      '~' => sub { ~$_[0]->{pid} },         # since 0.37
      '<=>' => sub { $_[2] ? $_[1] <=> $_[0]->{pid} : $_[0]->{pid} <=> $_[1] },
      'cmp' => sub { $_[2] ? $_[1] cmp $_[0]->{pid} : $_[0]->{pid} cmp $_[1] },
      '-'   => sub { $_[2] ? $_[1]  -  $_[0]->{pid} : $_[0]->{pid}  -  $_[1] },
      '/'   => sub { $_[2] ? $_[1]  /  $_[0]->{pid} : $_[0]->{pid}  /  $_[1] },
      '%'   => sub { $_[2] ? $_[1]  %  $_[0]->{pid} : $_[0]->{pid}  %  $_[1] },
      '**'  => sub { $_[2] ? $_[1]  ** $_[0]->{pid} : $_[0]->{pid}  ** $_[1] },
      '<<'  => sub { $_[2] ? $_[1]  << $_[0]->{pid} : $_[0]->{pid}  << $_[1] },
      '>>'  => sub { $_[2] ? $_[1]  >> $_[0]->{pid} : $_[0]->{pid}  >> $_[1] },
      'x'   => sub { $_[2] ? $_[1]  x  $_[0]->{pid} : $_[0]->{pid}  x  $_[1] },
      'cos'  => sub { cos $_[0]->{pid} },
      'sin'  => sub { sin $_[0]->{pid} },
      'exp'  => sub { exp $_[0]->{pid} },
      'log'  => sub { log $_[0]->{pid} },
      'sqrt' => sub { sqrt $_[0]->{pid} },
      'int'  => sub { int $_[0]->{pid} },
      'abs'  => sub { abs $_[0]->{pid} },
      'atan2' => sub { $_[2] ? atan2($_[1],$_[0]->{pid}) : atan2($_[0]->{pid},$_[1]) };
__enable_overload__
;
    if ($@) {
      carp "Error enabling overloading on Forks::Super::Job objects: $@\n";
    } elsif ($Forks::Super::Debug::DEBUG) {
        debug("Enabled overloading on Forks::Super::Job objects");
    }
  }
}

sub disable_overload {
  if ($OVERLOAD_ENABLED) {
    $OVERLOAD_ENABLED = 0;
    my $all_ops = join(",", map {'$_'} map {split/\s+/,$_} values %overload::ops);
    eval "no overload $all_ops";
  }
}

# returns a Forks::Super::Job object with the given identifier
sub get {
  my $id = shift;
  if (!defined $id) {
    Carp::cluck "undef value passed to Forks::Super::Job::get()";
  }
  if (defined $ALL_JOBS{$id}) {
    return $ALL_JOBS{$id};
  }
  return getByPid($id) || getByName($id);
}

sub getByPid {
  my $id = shift;
  if (is_number($id)) {
    my @j = grep { (defined $_->{pid} && $_->{pid} == $id) ||
		   (defined $_->{real_pid} && $_->{real_pid} == $id)
		 } @ALL_JOBS;
    return $j[0] if @j > 0;
  }
  return;
}

sub getByName {
  my $id = shift;
  my @j = grep { defined $_->{name} && $_->{name} eq $id } @ALL_JOBS;
  if (@j > 0) {
    return wantarray ? @j : $j[0];
  }
  return;
}

# retrieve a job object for a pid or job name, if necessary
sub _resolve {
  if (ref $_[0] ne 'Forks::Super::Job') {
    my $job = get($_[0]);
    if (defined $job) {
      return $_[0] = $job;
    }
    return $job;
  }
  return $_[0];
}

#
# count the number of active processes
#
sub count_active_processes {
  my $optional_pgid = shift;
  if (defined $optional_pgid) {
    return scalar grep {
      $_->{state} eq 'ACTIVE'
	and $_->{pgid} == $optional_pgid } @ALL_JOBS;
  }
  return scalar grep { defined $_->{state}
			 && $_->{state} eq 'ACTIVE' } @ALL_JOBS;
}

sub count_alive_processes {
  my ($count_bg, $optional_pgid) = @_;
  my @alive = grep { $_->{state} eq 'ACTIVE' ||
		     $_->{state} eq 'COMPLETE' ||
		     $_->{state} eq 'DEFERRED' ||
		     $_->{state} eq 'LAUNCHING' || # rare
		     $_->{state} eq 'SUSPENDED' ||
		     $_->{state} eq 'SUSPENDED-DEFERRED' 
		   } @ALL_JOBS;
  if (!$count_bg) {
    @alive = grep { $_->{_is_bg} == 0 } @alive;
  }
  if (defined $optional_pgid) {
    @alive = grep { $_->{pgid} == $optional_pgid } @alive;
  }
  return scalar @alive;
}

#
# _reap should distinguish:
#
#    all alive jobs (ACTIVE + COMPLETE + SUSPENDED + DEFERRED + SUSPENDED-DEFERRED)
#    all active jobs (ACTIVE + COMPLETE + DEFERRED)
#    filtered alive jobs (by optional pgid)
#    filtered ACTIVE + COMPLETE + DEFERRED jobs
#
#    if  all_active==0  and  all_alive>0,  
#    then see Wait::WAIT_ACTION_ON_SUSPENDED_JOBS
#
sub count_processes {
  my ($count_bg, $optional_pgid) = @_;
  my @alive = grep { $_->{state} ne 'REAPED' && $_->{state} ne 'NEW' } @ALL_JOBS;
  if (!$count_bg) {
    @alive = grep { $_->{_is_bg} == 0 } @alive;
  }
  my @active = grep { $_->{state} !~ /SUSPENDED/ } @alive;
  my @filtered_active = @active;
  if (defined $optional_pgid) {
    @filtered_active = grep { $_->{pgid} == $optional_pgid } @filtered_active;
  }

  my @n = (scalar(@filtered_active), scalar(@alive), scalar(@active));

  if ($Forks::Super::Debug::DEBUG) {
    debug("count_processes(): @n");
    debug("count_processes(): Filtered active: ",
	  $filtered_active[0]->toString()) if $n[0];
    debug("count_processes(): Alive: ", $alive[0]->toShortString()) if $n[1];
    debug("count_processes(): Active: @active") if $n[2];
  }

  return @n;
}

sub init_child {
  Forks::Super::Job::Ipc::init_child();
  return;
}

sub deinit_child {
  Forks::Super::Job::Ipc::deinit_child();
  close STDOUT if is_pipe(*STDOUT);
  close STDERR if is_pipe(*STDERR);
  close STDIN if *STDIN->opened && is_pipe(*STDIN);
}

#
# get the current CPU load. May not be possible
# to do on all operating systems.
#
sub get_cpu_load {
  return Forks::Super::Job::OS::get_cpu_load();
}

#
# Print information about all known jobs.
#
sub printAll {
  print "ALL JOBS\n";
  print "--------\n";
  foreach my $job
    (sort {$a->{pid} <=> $b->{pid} ||
	     $a->{created} <=> $b->{created}} @ALL_JOBS) {

      print $job->toString(), "\n";
      print "----------------------------\n";
    }
  return;
}

sub get_win32_proc { return $WIN32_PROC; }
sub get_win32_proc_pid { return $WIN32_PROC_PID; }

1;

__END__

=head1 NAME

Forks::Super::Job - object representing a background task

=head1 VERSION

0.38

=head1 SYNOPSIS

    use Forks::Super;

    $pid = Forks::Super::fork( \%options );  # see Forks::Super
    $job = Forks::Super::Job::get($pid);
    $job = Forks::Super::Job::getByName($name);

    print "Current job state is $job->{state}\n";
    print "Job was created at ", scalar localtime($job->{created}), "\n";

=head2 with overloading

See L</"OVERLOADING">.

    use Forks::Super 'overload';
    $job = Forks::Super::fork( \%options );
    print "Process id of new job is $job\n";
    print "Current state is ", $job->state, "\n";
    waitpid $job, 0;
    print "Exit status was ", $job->status, "\n";

=head1 DESCRIPTION

Calls to C<Forks::Super::fork()> that successfully spawn a child process or
create a deferred job (see L<Forks::Super/"Deferred processes">) will cause 
a C<Forks::Super::Job> instance to be created to track the job's state. 
For many uses of C<fork()>, it will not be necessary to query the state of 
a background job. But access to these objects is provided for users who 
want to exercise even greater control over their use of background
processes.

Calls to C<Forks::Super::fork()> that fail (return C<undef> or small negative
numbers) generally do not cause a new C<Forks::Super::Job> instance
to be created.

=head1 ATTRIBUTES

Use the C<Forks::Super::Job::get> or C<Forks::Super::Job::getByName>
methods to obtain a Forks::Super::Job object for
examination. The C<Forks::Super::Job::get> method takes a process ID or
job ID as an input (a value that may have been returned from a previous
call to C<Forks::Super::fork()> and returns a reference to a 
C<Forks::Super::Job> object, or C<undef> if the process ID or job ID 
was not associated with any known Job object. The 
C<Forks::Super::Job::getByName> looks up job objects by the 
C<name> parameter that may have been passed
in the C<Forks::Super::fork()> call.

A C<Forks::Super::Job> object has many attributes, some of which may
be of interest to an end-user. Most of these should not be overwritten.

=over 4

=item pid

Process ID or job ID. For deferred processes, this will be a
unique large negative number (a job ID). For processes that
were not deferred, this valud is the process ID of the
child process that performed this job's task.

=item real_pid

The process ID of the child process that performed this job's
task. For deferred processes, this value is undefined until
the job is launched and the child process is spawned.

=item pgid

The process group ID of the child process. For deferred processes,
this value is undefined until the child process is spawned. It is
also undefined for systems that do not implement
L<getpgrp|perlfunc/"getpgrp">.

=item created

The time (since the epoch) at which the instance was created.

=item start

The time at which a child process was created for the job. This
value will be undefined until the child process is spawned.

=item end

The time at which the child process completed and the parent
process received a C<SIGCHLD> signal for the end of this process.
This value will be undefined until the child process is complete.

=item reaped

The time at which a job was reaped via a call to
C<Forks::Super::wait>, C<Forks::Super::waitpid>, 
or C<Forks::Super::waitall>. Will be undefined until 
the job is reaped.

=item state

A string value indicating the current state of the job.
Current allowable values are

=over 4

=item C<DEFERRED>

For jobs that are on the job queue and have not started yet.

=item C<ACTIVE>

For jobs that have started in a child process

=item C<COMPLETE>

For jobs that have completed and caused the parent process to
receive a C<SIGCHLD> signal, but have not been reaped.

=item C<REAPED>

For jobs that have been reaped by a call to C<Forks::Super::wait>,
C<Forks::Super::waitpid>, or C<Forks::Super::waitall>.

=item C<SUSPENDED>

The job has started but it has been suspended (with a C<SIGSTOP>
or other appropriate mechanism for your operating system) and
is not currently running. A suspended job will not consume CPU
resources but my tie up memory, I/O, and network resources.

=item C<SUSPENDED-DEFERRED>

Job is in the job queue and has not started yet, and also
the job has been suspended.

=back

=item status

The exit status of a job. See L<CHILD_ERROR|perlvar/"CHILD_ERROR"> in
C<perlvar>. Will be undefined until the job is complete.

=item style

One of the strings C<natural>, C<cmd>, or C<sub>, indicating
whether the initial C<fork> call returned from the child process or whether
the child process was going to run a shell command or invoke a Perl
subroutine and then exit.

=item cmd

The shell command to run that was supplied in the C<fork> call.

=item sub

=item args

The name of or reference to CODE to run and the subroutine
arguments that were supplied in the C<fork> call.

=item _on_busy

The behavior of this job in the event that the system was
too "busy" to enable the job to launch. Will have one of
the string values C<block>, C<fail>, or C<queue>.

=item queue_priority

If this job was deferred, the relative priority of this
job.

=item can_launch

By default undefined, but could be a CODE reference
supplied in the C<fork()> call. If defined, it is the
code that runs when a job is ready to start to determine
whether the system is too busy or not.

=item depend_on

If defined, contains a list of process IDs and job IDs that
must B<complete> before this job will be allowed to start.

=item depend_start

If defined, contains a list of process IDs and job IDs that
must B<start> before this job will be allowed to start.

=item start_after

Indicates the earliest time (since the epoch) at
which this job may start.

=item expiration

Indicates the latest time that this job may be allowed to
run. Jobs that run past their expiration parameter will
be killed.

=item os_priority

Value supplied to the C<fork> call about desired
operating system priority for the job.

=item cpu_affinity

Value supplied to the C<fork> call about desired
CPU's for this process to prefer.

=item child_stdin

=item child_stdout

=item child_stderr

If the job has been configured for interprocess communication,
these attributes correspond to the handles for passing
standard input to the child process, and reading standard 
output and standard error from the child process, respectively.

=back

=cut

=head1 FUNCTIONS

=over 4

=head3 get

=item C< $job = Forks::Super::Job::get($pidOrName) >

Looks up a C<Forks::Super::Job> object by a process ID/job ID
or L<name|Forks::Super/"name"> attribute and returns the
job object. Returns C<undef> for an unrecognized pid or
job name.

=item C< $n = Forks::Super::Job::count_active_processes() >

Returns the current number of active background processes.
This includes only

=over 4

=item 1. First generation processes. Not the children and
grandchildren of child processes.

=item 2. Processes spawned by the C<Forks::Super> module,
and not processes that may have been created outside the
C<Forks::Super> framework, say, by an explicit call to
C<CORE::fork()>, a call like C<system("./myTask.sh &")>,
or a form of Perl's C<open> function that launches an
external command.

=back

=back

=head1 METHODS

A C<Forks::Super::Job> object recognizes the following methods.
In general, these methods should only be used from the foreground
process (the process that spawned the background job).

=over 4

=head3 waitpid

=item C<< $job->wait( [$timeout] ) >>

=item C<< $job->waitpid( $flags [,$timeout] ) >>

Convenience method to wait until or test whether the specified
job has completed. See L<Forks::Super::waitpid|Forks::Super/"waitpid">.

=head3 kill

=item C<< $job->kill($signal) >>

Convenience method to send a signal to a background job.
See L<Forks::Super::kill|Forks::Super/"kill">.

=head3 suspend

=item C<< $job->suspend >>

When called on an active job, suspends the background process with 
C<SIGSTOP> or other mechanism appropriate for the operating system.

=head3 resume

=item C<< $job->resume >>

When called on a suspended job (see L<< suspend|"$job->suspend" >>,
above), resumes the background process with C<SIGCONT> or other mechanism 
appropriate for the operating system.

=head3 is_E<lt>stateE<gt>

=item C<< $job->is_complete >>

Indicates whether the job is in the C<COMPLETE> or C<REAPED> state.

=item C<< $job->is_started >>

Indicates whether the job has started in a background process.
While return a false value while the job is still in a deferred state.

=item C<< $job->is_active >>

Indicates whether the specified job is currently running in
a background process.

=item C<< $job->is_suspended >>

Indicates whether the specified job has started but is currently
in a suspended state.

=head3 toString

=item C<< $job->toString() >>

=item C<< $job->toShortString() >>

Outputs a string description of the important features of the job.

=head3 write_stdin

=item C<< $job->write_stdin(@msg) >>

Writes the specified message to the child process's standard input
stream, if the child process has been configured to receive
input from interprocess communication. Writing to a closed 
handle or writing to a process that is not configured for IPC
will result in a warning.

=head3 read_stdXXX

=item C<< $line = $job->read_stdout() >>

=item C<< @lines = $job->read_stdout() >>

=item C<< $line = $job->read_stderr() >>

=item C<< @lines = $job->read_stderr() >>

In scalar context, attempts to read a single line, and in list
context, attempts to read all available lines from a child
process's standard output or standard error stream. 

If there is no available input, and if the C<Forks::Super> module
detects that the background job has completed (such that no more
input will be created), then the file handle will automatically be
closed. In scalar context, these methods will return C<undef>
if there is no input currently available on an inactive process,
and C<""> (empty string) if there is no input available on
an active process.

Reading from a closed handle, or calling these methods on a
process that has not been configured for IPC will result in
a warning.

=head3 close_fh

=item C<< $job->close_fh([@handle_id]) >>

Closes IPC filehandles for the specified job. Optional input
is one or more values from the set C<stdin>, C<stdout>, C<stderr>,
and C<all> to specify which filehandles to close. If no
parameters are provided, the default behavior is to close all
configured file handles.

On most systems, open filehandles are a scarce resource and it
is a very good practice to close filehandles when the jobs that
created them are finished running and you are finished processing
input and output on those filehandles.

=back

=head1 OVERLOADING

An experimental feature in the L<Forks::Super> module is to make
it more convenient to access the functionality of 
C<Forks::Super::Job>. When this feature is enabled, the 
return value from a call to C<Forks::Super::fork()> is an
I<overloaded> C<Forks::Super::Job> object. 

    $job_or_pid = fork { %options };

In a numerical context, this value looks and behaves like
a process ID (or job ID). The value can be passed to functions
like C<kill> and C<waitpid>.

    if ($job_or_pid != $another_pid) { ... }
    kill 'TERM', $job_or_pid;    

But you can also access the attributes and methods of the
C<Forks::Super::Job> object.

    $job_or_pid->{real_pid}
    $job_or_pid->suspend

Even when overloading is enabled, C<Forks::Super::fork()> 
still returns a simple scalar value of 0 to the child process
(when a value is returned).

B<Overloading is not enabled by default in this version
of C<Forks::Super> >. There are two ways you can enable this
feature:

When this feature is enabled, the return value of
L<Forks::Super::wait()|Forks::Super/"wait"> and
L<Forks::Super::waitpid()|Forks::Super/"waitpid"> might also
be an overload C<Forks::Super::Job> object. (But if C<wait>/C<waitpid>
is returning an indicator value like C<0> or C<-1>, then those
return values are just simple scalars.)

=over 4

=item 1. Pass the C<overload> parameter when C<Forks::Super> is loaded.

    use Forks::Super 'overload';
    $job = fork { sub => { sleep 5 } };
    print "New job: ", $job->toString(), "\n";

=item 2. Call C<Forks::Super::Job::enable_overload()>.

C<Forks::Super::Job::enable_overload()> enables this
feature at run-time.

    use Forks::Super;
    $pid = fork { cmd => [ "./mycommand.sh", "--42" ] };
    print ref $pid;    # empty string

    Forks::Super::Job::enable_overload();
    $pid = fork { cmd => [ "./mycommand.sh", "--19" ] };
    print ref $pid;    # Forks::Super::Job

There is also a C<Forks::Super::Job::disable_overload()> 
function to disable this feature at run-time. In principle,
you should be able to enable and disable this feature as
often as you wish.

=back

=head1 SEE ALSO

L<Forks::Super>.

=head1 AUTHOR

Marty O'Brien, E<lt>mob@cpan.orgE<gt>

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2009-2010, Marty O'Brien.

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.

=cut
