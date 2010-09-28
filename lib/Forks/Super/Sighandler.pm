#
# Forks::Super::Sighandler - tie %SIG to allow us to set
# up multiple signal handlers on a signal.
#

package Forks::Super::Sighandler;
use Exporter;
use Carp;
use strict;
use warnings;

our @ISA = qw(Exporter);
our @EXPORT = qw(register_signal_handler);
our $VERSION = $Forks::Super::Util::VERSION;

our %REGISTRY;
our $DEBUG = 0;
my $REGISTRY_MAX = 100;
my %SIGTABLE;
my $SIGTIE = bless {} , __PACKAGE__;

sub import {
  use Config;
  my @signo = split ' ',$Config{sig_num};
  my @signame = split ' ', $Config{sig_name};
  for (my $i=0; $i<@signo; $i++) {
    my $signo = $signo[$i];
    my $signame = $signame[$i];
    $SIGTABLE{$signo} ||= $signame;
    $SIGTABLE{'SIG' . $signame} = $SIGTABLE{$signame} = $SIGTABLE{$signo};
  }
  $SIGTABLE{__WARN__} = "__WARN__";
  $SIGTABLE{__DIE__} = "__DIE__";

  untie %SIG;
  for (keys %SIG) {
    if (defined $SIG{$_}) {
      carp "REGISTRY{$_}[50] => $SIG{$_}\n" if $DEBUG;
    }
    $REGISTRY{$_}[50] = $SIG{$_};
  }
  tie %SIG, __PACKAGE__;

  Forks::Super::Sighandler->export_to_level(1, @_);
}

sub untied (&) {
  my $BLOCK = shift;
  my @r;
  untie %SIG;
  @r = wantarray ? $BLOCK->() : scalar $BLOCK->();
  tie %SIG, __PACKAGE__;
  wantarray ? @r : $r[0];
}

sub init_child {
  # which signal handlers should be inherited by a new child process?
  # Basically, all of them. See Signal::Handler::Super/spike/inherit.pl .
  #
  # All we would want to do here is to disable certain signal handlers
  # that were installed by Forks::Super to perform parent-specific tasks.

  # IPC cleanup
  foreach my $sig (keys %SIG) {
    register_signal_handler($sig, 35, undef);
  }

  # Queue monitor
  register_signal_handler("ALRM", 10, undef);
  register_signal_handler("ALRM", 12, undef);
  register_signal_handler("CHLD", 10, undef);
}

######### hash tie routines ############

sub TIEHASH { $SIGTIE }
sub FETCH { return $REGISTRY{$_[1]}[50] }
sub STORE { 
  my $old = $REGISTRY{$_[1]}[50];
  register_signal_handler($_[1], 50, $_[2]);
  return $old
}
sub DELETE { return $_[0]->STORE($_[1], undef) }
sub CLEAR { }  # not recommended, noop
sub EXISTS { return exists $REGISTRY{$_[1]} };
sub FIRSTKEY { keys %REGISTRY; each %REGISTRY }
sub NEXTKEY { each %REGISTRY }
sub UNTIE { }

sub register_signal_handler ($$$) {
  # XXX - assume (1) $index provided, (2) $signal is canonical signal name,
  #       (3) $handler name is qualified correctly.  Signal::Handler::Super
  #       can relax all three of those assumptions
  my ($signal, $index, $handler) = @_;

  if ($signal !~ /__\w+__/ && defined $handler) {
    carp "$$ REGISTRY{$signal}[$index] => $handler\n" if $DEBUG;
  }

  if (!exists $REGISTRY{$signal}) {
    carp "Bad signal: $signal. Cannot register handler.\n";
    return;
  }
  $REGISTRY{$signal}[$index] = $handler;
  my @index_list = _get_index_list($signal);
  if (@index_list == 0) {
    no warnings 'uninitialized';
    untied { $SIG{$signal} = undef };
    return $index;
  }
  if (@index_list == 1) {
    my $handler = $REGISTRY{$signal}[$index_list[0]];
    if ($handler eq 'DEFAULT') {
      untied { $SIG{$signal} = 'DEFAULT' };
      return $index;
    } elsif ($handler eq 'IGNORE') {
      untied { $SIG{$signal} = 'IGNORE' };
      return $index;
    } else {
      untied { $SIG{$signal} = $handler };
      return $index;
    }
  }
  my $shadow = $signal eq '__WARN__' ? \&shadow__warn__handler
    : $signal eq '__DIE__' ? \&shadow__die__handler
      : \&shadow_signal_handler;
  untied { $SIG{$signal} = $shadow };
  return $index;
}

sub shadow_signal_handler {
  my ($signal, @args) = @_;
  if ($DEBUG) {
    if ($signal eq 'ALRM') {
      Carp::cluck "shadow signal handler $signal @args called\n";
    } else {
      # carp "shadow signal handler $signal @args called\n";
    }
  }
  for my $subhandler (@{$REGISTRY{$signal}}) {
    next if !defined($subhandler) || $subhandler eq 'IGNORE';
    carp "    invoking subhandler $subhandler for $signal\n" if $DEBUG;
    if ($subhandler eq 'DEFAULT') {
      _emulate_default($signal, @args);
    } elsif ($signal =~ /__\w+__/) {
      $subhandler->(@args);
    } else {
      $subhandler->($signal, @args);
    }
  }
}

sub shadow__warn__handler { shadow_signal_handler('__WARN__', @_) }
sub shadow__die__handler { shadow_signal_handler('__DIE__', @_) }
sub _emulate_default {
  my $signal = shift;

  if ($signal eq '__WARN__') {
    warn @_;
    return;
  }
  if ($signal eq '__DIE__') {
    die @_;
    return;
  }
  if ($signal eq 'CHLD' || $signal eq 'CLD' || $signal eq 'ZERO') {
    return;
  }
  if ($signal eq 'USR1') {
    die "User defined signal 1\n";
  } elsif ($signal eq 'USR2') {
    die "User defined signal 2\n";
  }

  exit 128 + 0;
}

sub _get_index_list {
  my $signal = shift;
  my @list = ();
  my %seen = ();
  my @list1 = grep { defined $REGISTRY{$signal}[$_] } 0..99;
  for my $i (@list1) {
    my $handler = $REGISTRY{$signal}[$i];
    next if !defined $handler;
    next if ($handler eq 'DEFAULT' || $handler eq 'IGNORE')
      && $seen{$handler}++;
    push @list, $i;
  }
  return @list;
}



# this package could probably be a separate distribution

1;

__END__


Signal handling, since v0.40

Where available, signals are used throughout Forks::Super.
Where they are not available (MSWin32), we still try to run
the "signal handlers" every once in a while.

Parent SIGCHLD handler:

    Indicates that a child process is finished. 
    Call CORE::waitpid and do an "internal reap"

Child SIGALRM handler:

    Indicates that a child has "timed out" or expired.
    Should cause a kill signal (HUP? TERM? QUIT? INT?) to be
    sent to any grandchild processes.

Parent SIGHUP|SIGINT|SIGTERM|SIGQUIT|SIGPIPE handlers

    If parent process is interrupted, we still want the parent
    to run "clean up" code, especially if IPC files 
    were used.

Parent periodic tasks [SIGUSR1 | SIGALRM]

    Parent processes have some periodic tasks that they
    should perform from time to time:
      - Examine the job queue and dispatch jobs
      - Clean the pipes -- do non-blocking read on any
        open pipe/sockethandles and buffer the input
      - Call SIGCHLD handler to reap jobs where we might
        have missed a SIGCHLD

Child periodic tasks

    Periodic tasks in the child
      - Clean pipes
      - Check if command has timed out yet.
      - See if a user's alarm has gone off

We want a framework where we can add and remove jobs
for the signal handlers to do at will. If end user
also wishes to add a signal handler, the framework
should be able to accomodate that, too. And transparently.

Let's spike it out ...




