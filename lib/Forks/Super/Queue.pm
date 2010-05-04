#
# Forks::Super::Queue - routines to manage "deferred" jobs
#

package Forks::Super::Queue;

use Forks::Super::Config;
use Forks::Super::Debug qw(:all);
use Forks::Super::Tie::Enum;
use Carp;
use Exporter;
use base 'Exporter';
use strict;
use warnings;

our @EXPORT_OK = qw(queue_job);
our %EXPORT_TAGS = (all => \@EXPORT_OK);

our (@QUEUE, $QUEUE_MONITOR_PID, $QUEUE_MONITOR_PPID);

our $QUEUE_MONITOR_FREQ;
our $DEFAULT_QUEUE_PRIORITY = 0;
our $INHIBIT_QUEUE_MONITOR = 1;
our $NEXT_DEFERRED_ID = -100000;
our $OLD_SIG;
our $VERSION = $Forks::Super::Debug::VERSION;
our $MAIN_PID = $$;
#our $QUEUE_MONITOR_LAUNCHED = 0;
our $_LOCK = 0; # ??? can this prevent crash -- no, but it can cause deadlock
our $CHECK_FOR_REAP = 1;
our $QUEUE_DEBUG = $ENV{FORKS_SUPER_QUEUE_DEBUG} || 0;
# set flag if the program is shutting down. Use flag in queue_job()
# to suppress warning messages
our $DURING_GLOBAL_DESTRUCTION = 0;

# use var $Forks::Super::QUEUE_INTERRUPT, not lexical package var

sub get_default_priority {
  my $q = $DEFAULT_QUEUE_PRIORITY;
  $DEFAULT_QUEUE_PRIORITY -= 1.0E-6;
  return $q;
}

sub init {
  tie $QUEUE_MONITOR_FREQ, 
    'Forks::Super::Queue::QueueMonitorFreq', 30;

  tie $Forks::Super::QUEUE_INTERRUPT, 
    'Forks::Super::Queue::QueueInterrupt', ('', keys %SIG);

  tie $INHIBIT_QUEUE_MONITOR, 
    'Forks::Super::Queue::InhibitQueueMonitor', 
    $^O eq 'MSWin32'; # XXX - or any other $^O with crippled signal framework

  if (grep {/USR1/} keys %SIG) {
    $Forks::Super::QUEUE_INTERRUPT = 'USR1';
  }

}

sub init_child {
  @QUEUE = ();
  if (defined $SIG{'USR2'}) {
    $SIG{'USR2'} = 'DEFAULT';
  }
  undef $QUEUE_MONITOR_PID;
  if ($Forks::Super::QUEUE_INTERRUPT
      && Forks::Super::Config::CONFIG('SIGUSR1')) {
    $SIG{$Forks::Super::QUEUE_INTERRUPT} = 'DEFAULT';
  }
}

#
# once there are jobs in the queue, we'll need to call
# run_queue() every once in a while to make sure those
# jobs get started when they are eligible. Certain
# events (the CHLD handler being invoked, the
# waitall method) call run_queue but that still doesn't
# guarantee that it will be called frequently enough.
#
# This method sets up a background process (using
# CORE::fork -- it won't be subject to reaping by
# this module's wait/waitpid/waitall methods)
# to periodically send USR1^H^H^H^H
# $Forks::Super::QUEUE_INTERRUPT signals to this
#
sub _launch_queue_monitor {
  if (!Forks::Super::Config::CONFIG('SIGUSR1')) {
    debug("_lqm returning: no SIGUSR1") if $QUEUE_DEBUG;
    return;
  }
  if (defined $QUEUE_MONITOR_PID) {
    debug("_lqm returning: \$QUEUE_MONITOR_PID defined") if $QUEUE_DEBUG;
    return;
  }
  if (!(defined $Forks::Super::QUEUE_INTERRUPT
	&& $Forks::Super::QUEUE_INTERRUPT)) {
    debug("_lqm returning: \$Forks::Super::QUEUE_INTERRUPT not set")
      if $QUEUE_DEBUG;
    return;
  }

  $OLD_SIG = $SIG{$Forks::Super::QUEUE_INTERRUPT};
  $SIG{$Forks::Super::QUEUE_INTERRUPT} = \&Forks::Super::Queue::check_queue;
  $QUEUE_MONITOR_PPID = $$;
  $QUEUE_MONITOR_PID = CORE::fork();
  if (not defined $QUEUE_MONITOR_PID) {
    warn "Forks::Super: ",
      "queue monitoring sub process could not be launched: $!\n";
    undef $QUEUE_MONITOR_PPID;
    return;
  }
  if ($QUEUE_MONITOR_PID == 0) {
    $0 = "$QUEUE_MONITOR_PPID:QMon";
    if ($DEBUG || $QUEUE_DEBUG) {
      debug("Launching queue monitor process $$ ",
	    "SIG $Forks::Super::QUEUE_INTERRUPT ",
	    "PPID $QUEUE_MONITOR_PPID ",
	    "FREQ $QUEUE_MONITOR_FREQ ");
    }

    if (defined &Forks::Super::init_child) {
      Forks::Super::init_child();
    } else {
      init_child();
    }
    for (;;) {
      sleep $QUEUE_MONITOR_FREQ;
      if ($DEBUG || $QUEUE_DEBUG) {
	debug("queue monitor $$ passing signal to $QUEUE_MONITOR_PPID");
      }
      CORE::kill $Forks::Super::QUEUE_INTERRUPT, $QUEUE_MONITOR_PPID;
    }
    exit 0;
  }
  return;
}

sub _kill_queue_monitor {
  if (defined $QUEUE_MONITOR_PPID && $$ == $QUEUE_MONITOR_PPID) {
    if (defined $QUEUE_MONITOR_PID && $QUEUE_MONITOR_PID > 0) {

      if ($DEBUG || $QUEUE_DEBUG) {
	debug("killing queue monitor $QUEUE_MONITOR_PID");
      }
      CORE::kill 'INT', $QUEUE_MONITOR_PID;
      my $z = CORE::waitpid $QUEUE_MONITOR_PID, 0;
      if ($DEBUG || $QUEUE_DEBUG) {
	debug("kill queue monitor result: $z");
      }

      undef $QUEUE_MONITOR_PID;
      undef $QUEUE_MONITOR_PPID;
      if (defined $OLD_SIG) {
	$SIG{$Forks::Super::QUEUE_INTERRUPT} = $OLD_SIG;
      }
    }
  }
}


END {
  $DURING_GLOBAL_DESTRUCTION = 1;
  _kill_queue_monitor();
}

#
# add a new job to the queue.
# may run with no arg to populate queue from existing
# deferred jobs
#
sub queue_job {
  my $job = shift;
  if ($DURING_GLOBAL_DESTRUCTION) {
    return;
  }
  if (defined $job) {
    $job->{state} = 'DEFERRED';
    $job->{pid} = $NEXT_DEFERRED_ID--;
    $Forks::Super::ALL_JOBS{$job->{pid}} = $job;
    if ($DEBUG || $QUEUE_DEBUG) {
      debug("queueing job ", $job->toString());
    }
  }

  my @q = grep { $_->{state} eq 'DEFERRED' } @Forks::Super::ALL_JOBS;
  @QUEUE = @q;
  if (@QUEUE > 0 && !$QUEUE_MONITOR_PID && !$INHIBIT_QUEUE_MONITOR) {
    _launch_queue_monitor();
  } elsif (@QUEUE == 0 && defined $QUEUE_MONITOR_PID) {
    _kill_queue_monitor();
  }
  return;
}

our $_REAP;

sub _check_for_reap {
  if ($CHECK_FOR_REAP && $_REAP > 0) {
    if ($DEBUG || $QUEUE_DEBUG) {
      debug("reap during queue examination -- restart");
    }
    return 1;
  }
}


#
# attempt to launch all jobs that are currently in the
# DEFFERED state.
#
sub run_queue {
  my ($ignore) = @_;
  return if @QUEUE <= 0;
  # XXX - run_queue from child ok if $Forks::Super::CHILD_FORK_OK
  return if $$ != ($Forks::Super::MAIN_PID || $MAIN_PID);
  queue_job();
  return if @QUEUE <= 0;
  if ($_LOCK++ > 0) {
    $_LOCK--;
    return;
  }

  # tasks for run_queue:
  #   assemble all DEFERRED jobs
  #   order by priority
  #   go through the list and attempt to launch each job in order.

  debug('run_queue(): examining deferred jobs') if $DEBUG || $QUEUE_DEBUG;
  my $job_was_launched;
  do {
    $job_was_launched = 0;
    $_REAP = 0;
    my @deferred_jobs = grep {
      defined $_->{state} && $_->{state} eq 'DEFERRED'
    } @Forks::Super::ALL_JOBS;
    @deferred_jobs = sort {
      $b->{queue_priority} || 0 <=> $a->{queue_priority} || 0
    } @deferred_jobs;

    foreach my $job (@deferred_jobs) {
      if ($job->can_launch) {
	if ($job->{debug}) {
	  debug("Launching deferred job $job->{pid}")
	}
	$job->{state} = 'LAUNCHING';

	# if this loop gets interrupted to handle a child,
	# we might be launching jobs in the wrong order.
	# If we detect that an interruption has happened,
	# abort and restart the loop.
	#
	# To disable this check, set 
	# $Forks::Super::Queue::CHECK_FOR_REAP := 0

	if (_check_for_reap()) {
	  $job->{state} = 'DEFERRED';
	  $job_was_launched = 1;
	  last;
	}
	my $pid = $job->launch();
	if ($pid == 0) {
	  if (defined $job->{sub} or defined $job->{cmd}
	      or defined $job->{exec}) {
	    $_LOCK--;
	    croak "Forks::Super::run_queue(): ",
	      "fork on deferred job unexpectedly returned ",
		"a process id of 0!\n";
	  }
	  $_LOCK--;
	  croak "Forks::Super::run_queue(): ",
	    "deferred job must have a 'sub', 'cmd', or 'exec' option!\n";
	}
	$job_was_launched = 1;
	last;
      } elsif ($job->{debug}) {
	debug("Still must wait to launch job ", $job->toShortString());
      }
    }
  } while ($job_was_launched);

  if (0) {   # suspend/resume callback under development
    my @suspended_jobs = grep { $_->{state} eq 'SUSPENDED'
			      } @Forks::Super::ALL_JOBS;
    my @active_and_suspendable_jobs 
      = grep { $_->{state} eq 'ACTIVE' 
		 && defined $_->{suspend} } @Forks::Super::ALL_JOBS;

    foreach my $j (@active_and_suspendable_jobs) {
      if ($j->{suspend}->() < 0) {
	$j->suspend;
      }
    }
    foreach my $j (@suspended_jobs) {
      if ($j->{suspend}->() > 0) {
	$j->resume;
      }
    }
  }

  $_LOCK--;
  return;
}

#
# SIGUSR1 handler. A background process will send periodic USR1^H^H^H^H
# $Forks::Super::QUEUE_INTERRUPT signals back to this process. On
# receipt of these signals, this process should examine the queue.
# This will keep us from ignoring the queue for too long.
#
# Note this automatic housecleaning is not available on some OS's
# like Windows. Those users may need to call  Forks::Super::Queue::check_queue
# or  Forks::Super::run_queue  manually from time to time.
#
sub check_queue {
  run_queue() if !$_LOCK;
  return;
}

#############################################################################

# when $Forks::Super::Queue::QUEUE_MONITOR_FREQ is updated,
# we should restart the queue monitor.

sub Forks::Super::Queue::QueueMonitorFreq::TIESCALAR {
  my ($class,$value) = @_;
  $value = int $value;
  if ($value == 0) {
    $value = 1;
  } elsif ($value < 0) {
    $value = 30;
  }
  debug("new F::S::Q::QueueMonitorFreq obj") if $QUEUE_DEBUG;
  return bless \$value, $class;
}

sub Forks::Super::Queue::QueueMonitorFreq::FETCH {
  my $self = shift;
  debug("F::S::Q::QueueMonitorFreq::FETCH: $$self") if $QUEUE_DEBUG;
  return $$self;
}

sub Forks::Super::Queue::QueueMonitorFreq::STORE {
  my ($self,$new_value) = @_;
  $new_value = int($new_value) || 1;
  $new_value = 30 if $new_value < 0;
  if ($new_value == $$self) {
    debug("F::S::Q::QueueMonitorFreq::STORE noop $$self") if $QUEUE_DEBUG;
    return $$self;
  }
  if ($QUEUE_DEBUG) {
    debug("F::S::Q::QueueMonitorFreq::STORE $$self <== $new_value");
  }
  $$self = $new_value;
  _kill_queue_monitor();
  run_queue();
  _launch_queue_monitor() if @QUEUE > 0;
}

#############################################################################

# When $Forks::Super::Queue::INHIBIT_QUEUE_MONITOR is changed to non-zero,
# always call _kill_queue_monitor.

sub Forks::Super::Queue::InhibitQueueMonitor::TIESCALAR {
  my ($class,$value) = @_;
  $value = 0+!!$value;
  return bless \$value, $class;
}

sub Forks::Super::Queue::InhibitQueueMonitor::FETCH {
  my $self = shift;
  return $$self;
}

sub Forks::Super::Queue::InhibitQueueMonitor::STORE {
  my ($self, $new_value) = @_;
  $new_value = 0+!!$new_value;
  if ($$self != $new_value && $new_value) {
    _kill_queue_monitor();
  }
  $$self = $new_value;
  return $$self;
}

#############################################################################

# Restart queue monitor if value for $QUEUE_INTERRUPT is changed.

*Forks::Super::Queue::QueueInterrupt::TIESCALAR
  = \&Forks::Super::Tie::Enum::TIESCALAR;

*Forks::Super::Queue::QueueInterrupt::FETCH
  = \&Forks::Super::Tie::Enum::FETCH;

sub Forks::Super::Queue::QueueInterrupt::STORE {
  my ($self, $new_value) = @_;
  if (uc $new_value eq uc Forks::Super::Tie::Enum::_get_value($self)) {
    return; # no change
  }
  if (!Forks::Super::Tie::Enum::_has_attr($self,$new_value)) {
    return; # invalid assignment
  }
  _kill_queue_monitor();
  $Forks::Super::Tie::Enum::VALUE{$self} = $new_value;
  _launch_queue_monitor() if @QUEUE > 0;
  return;
}

#############################################################################

1;
