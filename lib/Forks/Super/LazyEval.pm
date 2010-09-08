#
# Forks::Super::LazyEval - bg_eval, bg_qx implementations
#

package Forks::Super::LazyEval;

use base 'Exporter';
use Forks::Super::Config qw(:all);
use Carp; 
use strict; 
use warnings;

our @EXPORT = qw(bg_eval bg_qx);

$Forks::Super::LazyEval::USE_ZCALAR = 0;   # enable experimental feature

sub bg_eval (&;@) {
  my $useYAML = CONFIG('YAML');
  my $useJSON2 = CONFIG('JSON') && $JSON::VERSION >= 2.0;
  my $useJSON1 = CONFIG('JSON') && $JSON::VERSION < 2.0;
  if (!($useYAML || $useJSON2 || $useJSON1)) {
    croak "Forks::Super: bg_eval call requires either YAML or JSON\n";
  }
  my ($code, @other_options) = @_;
  if (@other_options > 0 && ref $other_options[0] eq 'HASH') {
    @other_options = %{$other_options[0]};
  }
  my $p = $$;
  my ($result, @result);
  if (wantarray) {
    require Forks::Super::Tie::BackgroundArray;
    tie @result, 'Forks::Super::Tie::BackgroundArray',
      'eval', $code, 
      use_YAML => $useYAML, 
      use_JSON => $useJSON2, 
      use_JSON2 => $useJSON2,
      use_JSON1 => $useJSON1,
      @other_options;
    return @result;
  } elsif ($Forks::Super::LazyEval::USE_ZCALAR) {

    # Forks::Super::Tie::BackgroundZcalar is experimental replacement for
    # Forks::Super::Tie::BackgroundScalar using overloading that would not
    # require dereferencing to get the result.

    require Forks::Super::Tie::BackgroundZcalar;
    $result = new Forks::Super::Tie::BackgroundZcalar
      'eval', $code, 
      use_YAML => $useYAML, 
      use_JSON => $useJSON2,
      use_JSON2 => $useJSON2,
      use_JSON1 => $useJSON1,
      @other_options;
    if ($$ != $p) {
      # a WTF observed on Windows
      croak "Forks::Super::bg_eval: ",
	"Inconsistency in process IDs: $p changed to $$!\n";
    }
    return $result;
  } else {
    require Forks::Super::Tie::BackgroundScalar;
    tie $result, 'Forks::Super::Tie::BackgroundScalar',
      'eval', $code, 
      use_YAML => $useYAML, 
      use_JSON => $useJSON2,
      use_JSON2 => $useJSON2,
      use_JSON1 => $useJSON1,
      @other_options;
    if ($$ != $p) {
      # a WTF observed on Windows
      croak "Forks::Super::bg_eval: ",
	"Inconsistency in process IDs: $p changed to $$!\n";
    }
    return \$result;
  }
}

sub bg_qx {
  my ($command, @other_options) = @_;
  if (@other_options > 0 && ref $other_options[0] eq 'HASH') {
    @other_options = %{$other_options[0]};
  }
  my $p = $$;
  my (@result, $result);
  if (wantarray) {
    require Forks::Super::Tie::BackgroundArray;
    tie @result, 'Forks::Super::Tie::BackgroundArray',
      'qx', $command, @other_options;
    return @result;
  } elsif ($Forks::Super::LazyEval::USE_ZCALAR) {
    require Forks::Super::Tie::BackgroundZcalar;
    $result =  new Forks::Super::Tie::BackgroundZcalar
      'qx', $command, @other_options;
    if ($$ != $p) {
      # a WTF observed on Windows
      croak "Forks::Super::bg_eval: ",
	"Inconsistency in process IDs: $p changed to $$!\n";
    }
    return $result;
  } else {
    require Forks::Super::Tie::BackgroundScalar;
    tie $result, 'Forks::Super::Tie::BackgroundScalar',
      'qx', $command, @other_options;
    if ($$ != $p) {
      # a WTF observed on Windows
      croak "Forks::Super::bg_eval: ",
	"Inconsistency in process IDs: $p changed to $$!\n";
    }
    return \$result;
  }
}

1;
