use Forks::Super ':test';
use Test::More tests => 2;
use strict;
use warnings;
$| = 1;

if (Forks::Super::CONFIG("alarm")) {
  alarm 60;$SIG{ALRM} = sub { die "Timeout $0 ran too long\n" };
}

#
# test whether a parent process can have access to the
# STDIN, STDOUT, and STDERR filehandles of a child
# process. This features allows for communication
# between parent and child processes.
#

##################################################

#
# a proof-of-concept: pass strings to a child 
# and receive back the checksums
#

sub compute_checksums_in_child {
  binmode STDOUT;
  for (;;) {
#    if (defined getsockname(STDIN)) {
#      $_ = Forks::Super::_read_socket(undef, *STDIN, 0);
#    } else {
#      $_ = <STDIN>;
#    }
    $_ = <STDIN>;
    if (not defined $_) {
      Forks::Super::pause();
      next;
    }
    s/\s+$//;
    last if $_ eq "__END__";
    print "$_\\", unpack("%32C*",$_)%65535,"\n";
  }
}

my @pids = ();
for (my $i=0; $i<4; $i++) {
  push @pids, fork { sub => \&compute_checksums_in_child, timeout => 20,
			child_fh => "in,out,pipe" };
}
my @data = (@INC,%INC,keys(%!),keys(%ENV));
my (@pdata, @cdata);
for (my $i=0; $i<@data; $i++) {
  print {$Forks::Super::CHILD_STDIN{$pids[$i%4]}} "$data[$i]\n";
  push @pdata, sprintf("%s\\%d\n", $data[$i], unpack("%32C*",$data[$i])%65535);
}
Forks::Super::write_stdin($_,"__END__\n") for @pids;
waitall;
foreach (@pids) {
  push @cdata, Forks::Super::read_stdout($_);
}
ok(@pdata > 0 && @pdata == @cdata, "parent & child processed "
   .(scalar @pdata)."/".(scalar @cdata)." strings");
@pdata = sort @pdata;
@cdata = sort @cdata;
my $pc_equal = 1;
for (my $i=0; $i<@pdata; $i++) {
  $pc_equal=0 if $pdata[$i] ne $cdata[$i] && print "$i: $pdata[$i] /// $cdata[$i] ///\n";
}
ok($pc_equal, "parent/child agree on output");

#######################################################################

use Carp;$SIG{SEGV} = sub { Carp::cluck "XXXXXXX Caught SIGSEGV during cleanup of $0 ...\n" };

__END__