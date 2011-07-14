#
# tied filehandle class for interprocess communication files created in
# Forks::Super. Mainly this class is for testing and debugging, though
# we may think of something to override in the future. 
#
# Until then, in principle we can drop this class in and out without
# changing the behavior of any application using Forks::Super.
#
# Suggested usage:
#
#     tie before opening
#     bless the original filehandle to 'Forks::Super::Tie::Delegator'
#         so that calls like  $fh->autoflush(1)  get executed by the
#         tied (i.e., the real) filehandle and not the masked one.
#
#
#     $fh = Forks::Super::Job::Ipc::_gensym();
#     tie *$fh, 'Forks::Super::Tie::ICPFileHandle';
#     bless $fh, 'Forks::Super::Tie::Delegator';
#     open $fh, ...
#

package Forks::Super::Tie::IPCFileHandle;

use Exporter;
use IO::Handle;
use Carp;
use strict;
use warnings;

our @ISA = qw(Exporter IO::Handle);

sub TIEHANDLE {
  my ($class, %props) = @_;
  my $self = bless Forks::Super::Job::Ipc::_gensym(), $class;
  $$self->{$_} = $props{$_} for keys %props;
  $$self->{created} = Time::HiRes::time();
  return $self;
}

#############################################################################

sub OPEN {
  my ($self, $mode, $expr) = @_;
  $$self->{OPEN}++;
  my ($result, $new_err);
  my $old_err = $!;
  if ($$self->{OPENED}) {
    # filehandle already open, implicit close
    $self->CLOSE;
  }

  {
    local $! = 0;
    if (defined $expr) {
      # XXX - we currently don't make calls with the 4+ arg version of open
      #       so we don't need to support it now, but one day we might.

      # suppress "Filehandle %s reopened as %s only for input/output",
      # which can occur when we close and reopen the STDxxx filehandles
      no warnings 'io';
      $result = open *$self, $mode, $expr;
    } else {
      $result = open *$self, $mode;         ## no critic (TwoArgOpen)
    }
    $$self->{opened} = ($$self->{OPENED} = $result) && Time::HiRes::time();
    $$self->{closed} = 1 if !$result;
    $$self->{open_error} = $new_err = $!;
  }
  $! = $new_err || $old_err;
  return $result;
}

sub BINMODE {
  my ($self, $layer) = @_;
  $$self->{BINMODE}++;
  return binmode *$self, $layer || ":raw";
}

sub READLINE {
  my $self = shift;
  $$self->{READLINE}++;
  return <$self>;
}

sub FILENO {
  my $self = shift;
  $$self->{FILENO}++;
  return $$self->{fileno} ||= CORE::fileno($self);
}

sub SEEK {
  my ($self, $whence, $position) = @_;
  $$self->{SEEK}++;
  return seek $self, $whence, $position;
}

sub GETC {
  my $self = shift;
  $$self->{GETC}++;
  return getc($self);
}

sub READ {
  my ($self, undef, $length, $offset) = @_;
  $$self->{READ}++;
  return read $self, $_[1], $length, $offset;
}

sub PRINT {
  my $self = shift;
  $$self->{PRINT}++;
  if ($$self->{closed}) {

    carp "print on closed fh ", *$self, " ", 
      $$self->{name}||'', " closed=",$$self->{closed},"\n";
    return;

  }
  my $z = print {$self} @_;
  IO::Handle::flush($self);
  return $z;
}

sub PRINTF {
  my $self = shift;
  $$self->{PRINTF}++;
  if ($$self->{closed}) {

    carp "printf on closed fh ", $$self->{name}, "\n";
    return;

  }
  seek $self, 0, 2;
  return printf {$self} @_;
}

sub TELL {
  my $self = shift;
  $$self->{TELL}++;
  return tell $self;
}

sub WRITE {
  my ($self, $string, $length, $offset) = @_;
  $$self->{WRITE}++;
  if ($$self->{closed}) {

    carp "write/syswrite on closed fh ", $$self->{name}, "\n";
    return;

  }
  seek $self, 0, 2;
  return syswrite $self, $string, $length||length($string), $offset||0;
}

sub CLOSE {
  my $self = shift;
  $$self->{CLOSE}++;
  if (!$$self->{closed}) {
    $$self->{closed} = Time::HiRes::time();

    my $elapsed = $$self->{closed} - $$self->{opened}||$$self->{created}||$^T;
    $$self->{elapsed} = $elapsed;
    my $result = close $self;
    delete $$self->{OPENED};
    return $result;
  }
  return;
}

sub EOF {
  my $self = shift;
  return eof $self;
}

sub is_pipe {
  return 0;
}

sub UNTIE {
    # XXX - without this method, we often get
    #   'untie attempted while ... inner references ...' message.
    my ($self, $existing_inner_references) = @_;
    if ($existing_inner_references > 1) {
	if (!$Forks::Super::Job::INSIDE_END_QUEUE) {
	    warn "untie attempted while ", $existing_inner_references,
	    	" still exist";
	}
    }
}

sub Forks::Super::Tie::Delegator::AUTOLOAD {
  my $method = $Forks::Super::Tie::Delegator::AUTOLOAD;
  $method =~ s/.*:://;
  my $tied = tied *{shift @_};
  if ($tied) {
    return eval "\$tied->$method(\@_)" or do {};  ## no critic (StringyEval)
  }

  if ($method eq 'DESTROY') {
      return;  # no op
  }

  if (!$Forks::Super::Job::INSIDE_END_QUEUE) {
    Carp::confess "Can't delegate method $method from an untied object!";
  }

  Carp::cluck "Delegation of $method requested for untied object ",
    	"during global destruction ...";
  return;
}

1;
