package Tie::Enum;
use Carp;
use strict;
use warnings;
use vars qw(%ATTR %VALUE);

# A tie'd scalar value that can only take on values
# from a pre-specified list.
# Used in Forks::Super for $ON_BUSY and $QUEUE_INTERRUPT

sub TIESCALAR {
  my ($class, @attr) = @_;
  my $self;
  bless \$self, $class;
  $VALUE{\$self} = $attr[0];
  $ATTR{\$self} = [ @attr ];
  return \$self;
}

sub FETCH {
  my $self = shift;
  return $VALUE{$self};
}

sub STORE {
  my ($self,$value) = @_;
  foreach my $attr (@{$ATTR{$self}}) {
    if (uc $value eq uc $attr) {
      $VALUE{$self} = $attr;
      return;
    }
  }
  if ($ATTR{""}) {
    $VALUE{$self} = "";
  } else {
    carp "Invalid assignment to enumerated tied scalar\n";
  }
}

1;

