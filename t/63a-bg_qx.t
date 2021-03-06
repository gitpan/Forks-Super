use Forks::Super ':test';
use Test::More tests => 16;
use strict;
use warnings;

if (${^TAINT}) {
    $ENV{PATH} = "";
    ($^X) = $^X =~ /(.*)/;
}

ok(!defined $Forks::Super::LAST_JOB, "\$Forks::Super::LAST_JOB not set");
ok(!defined $Forks::Super::LAST_JOB_ID, "\$Forks::Super::LAST_JOB_ID not set");
my $t2 = Time::HiRes::time();
my $z = sprintf "%05d", 100000 * rand();
my $x = bg_qx "$^X t/external-command.pl -e=$z -s=3";
my $t = Time::HiRes::time();
ok(defined $Forks::Super::LAST_JOB, "\$Forks::Super::LAST_JOB set");
ok(defined $Forks::Super::LAST_JOB_ID, "\$Forks::Super::LAST_JOB_ID set");
ok(Forks::Super::isValidPid($Forks::Super::LAST_JOB_ID), 
   "\$Forks::Super::LAST_JOB_ID set");
ok($Forks::Super::LAST_JOB->{_is_bg} > 0, 
   "\$Forks::Super::LAST_JOB marked bg");
my $p = waitpid -1, 0;
my $t3 = Time::HiRes::time() - $t;
okl($p == -1 && $t3 <= 1.5,
   "waitpid doesn't catch bg_qx job, fast fail ${t3}s expect <=1s");
ok($x eq "$z \n", "scalar bg_qx $x");
my $h = Time::HiRes::time();
($t,$t2) = ($h-$t,$h-$t2);
my $y = $x;
ok($y == $z, "scalar bg_qx");
okl($t2 >= 2.7 && $t <= 6.5,           ### 10 ### was 5.1 obs 5.57,6.31,2.75
    "scalar bg_qx took ${t}s ${t2}s expected ~3s");
$x = 19;
ok($x == 19, "result is not read only");

### interrupted bg_qx, scalar context ###

my $j = $Forks::Super::LAST_JOB;
$y = "";
$z = sprintf "B%05d", 100000 * rand();
$y = bg_qx "$^X t/external-command.pl -s=5 -s=5 -e=$z", { timeout => 2 };
$t = Time::HiRes::time();

ok(defined($y)==0 || "$y" eq "" || "$y" eq "\n",
   "scalar bg_qx empty on failure")  ### 12 ###
    or diag("\$y was $y, expected empty or undefined\n");
ok($j ne $Forks::Super::LAST_JOB, "\$Forks::Super::LAST_JOB updated");
$t = Time::HiRes::time() - $t;
okl($t <= 6.5,                        ### 14 ### was 4 obs 4.92,6.0,7.7!
    "scalar bg_qx respected timeout, took ${t}s expected ~2s");

### interrupted bg_qx, capture existing output ###

$z = sprintf "C%05d", 100000 * rand();
$x = bg_qx "$^X t/external-command.pl -e=$z -s=10", timeout => 4;
$t = Time::HiRes::time();
ok($x eq "$z \n" || $x eq "$z ",     ### 15 ###
   "scalar bg_qx failed but retrieved output")
    or diag("\$x was $x, expected $z\n");
if (!defined $x) {
    print STDERR "(output was: <undef>;target was \"$z \")\n";
} elsif ($x ne "$z \n" && $x ne "$z ") {
    print STDERR "(output was: $x; target was \"$z \")\n";
}
$t = Time::HiRes::time() - $t;
okl($t <= 7.5,                          ### 16 ### was 3 obs 3.62,5.88,7.34
    "scalar bg_qx respected timeout, took ${t}s expected ~4s");




sub hex_enc{join'', map {sprintf"%02x",ord} split//,shift} # for debug


