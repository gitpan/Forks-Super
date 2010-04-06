use Forks::Super ':test';
use Test::More tests => 32;
use strict;
use warnings;

ok(!defined $Forks::Super::LAST_JOB, "\$Forks::Super::LAST_JOB not set");
ok(!defined $Forks::Super::LAST_JOB_ID, "\$Forks::Super::LAST_JOB_ID not set");
my $t2 = Time();
my $z = sprintf "%05d", 100000 * rand();
my $x = bg_qx "$^X t/external-command.pl -e=$z -s=3";
my $t = Time();
ok(defined $Forks::Super::LAST_JOB, "\$Forks::Super::LAST_JOB set");
ok(defined $Forks::Super::LAST_JOB_ID, "\$Forks::Super::LAST_JOB_ID set");
ok(Forks::Super::isValidPid($Forks::Super::LAST_JOB_ID), 
	"\$Forks::Super::LAST_JOB_ID set");
ok($Forks::Super::LAST_JOB->{_is_bg} > 0, 
	"\$Forks::Super::LAST_JOB marked bg");
my $p = waitpid -1, 0;
my $t3 = Time() - $t;
ok($p == -1 && $t3 <= 1.5, 
	"waitpid doesn't catch bg_eval job, fast fail ${t3}s expect <=1s");
ok($$x eq "$z \n", "scalar bg_qx $$x");
my $h = Time();
($t,$t2) = ($h-$t,$h-$t2);
my $y = $$x;
ok($y == $z, "scalar bg_qx");
ok($t2 >= 2.8 && $t <= 5.5,           ### 10 ### was 5.1 obs 5.23,5.57
   "scalar bg_qx took ${t}s ${t2}s expected ~3s");
$$x = 19;
ok($$x == 19, "result is not read only");

### interrupted bg_qx, scalar context ###

my $j = $Forks::Super::LAST_JOB;
$y = "";
$z = sprintf "B%05d", 100000 * rand();
my $x2 = bg_qx "$^X t/external-command.pl -s=8 -e=$z", timeout => 2;
$t = Time();
$y = $$x2;

# if (!defined $y) { print "\$y,\$\$x is: <undef>\n"; } else { print "\$y,\$\$x is: \"$y\"\n"; }

#-- intermittent failure here: --#
ok((!defined $y) || $y eq "" || $y eq "\n", "scalar bg_qx empty on failure");
ok($j ne $Forks::Super::LAST_JOB, "\$Forks::Super::LAST_JOB updated");
if (defined $y && $y ne "" && $y ne "\n") {
	print STDERR "Fail on test 5: \$y: ", hex_enc($y), "\n";
	print STDERR `cat /tmp/qqq`;
}
$t = Time() - $t;
ok($t <= 4.15,                       ### 14 ### was 4 obs 4.12
   "scalar bg_qx respected timeout, took ${t}s expected ~2s");

### interrupted bg_qx, capture existing output ###

$z = sprintf "C%05d", 100000 * rand();
$x = bg_qx "$^X t/external-command.pl -e=$z -s=10", timeout => 2;
$t = Time();
ok($$x eq "$z \n" || $$x eq "$z ",   ### 15 ###
   "scalar bg_qx failed but retrieved output"); 
if (!defined $$x) {
  print STDERR "(output was: <undef>;target was \"$z \")\n";
} elsif ($$x ne "$z \n" && $$x ne "$z ") {
  print STDERR "(output was: $$x; target was \"$z \")\n";
}
$t = Time() - $t;
ok($t <= 6.0,                            ### 16 ### was 3 obs 3.62,5.88
   "scalar bg_qx respected timeout, took ${t}s expected ~2s");

### list context ###

$t = Time();
my @x = bg_qx "$^X t/external-command.pl -e=Hello -n -s=2 -e=World -n -s=2 -e=\"it is a\" -n -e=beautiful -n -e=day";
my @tests = @x;
$t = Time() - $t;
ok($tests[0] eq "Hello \n" && $tests[1] eq "World \n", "list bg_qx");
ok(@tests == 5, "list bg_qx");
ok($t >= 3.95, "list bg_qx took ${t}s expected ~4s");

# exercise array operations on the tie'd @x variable to make sure
# we implemented everything correctly 

my $n = @x;
my $u = shift @x;
ok($u eq "Hello \n" && @x == $n - 1, "list bg_qx shift");
$u = pop @x;
ok(@x == $n - 2 && $u =~ /day/, "list bg_qx pop");
unshift @x, "asdf";
ok(@x == $n - 1, "list bg_qx unshift");
push @x, "qwer", "tyuiop";
ok(@x == $n + 1, "list bg_qx push");
splice @x, 3, 3, "pq";
ok(@x == $n - 1 && $x[3] eq "pq", "list bg_qx splice");
$x[3] = "rst";
ok(@x == $n - 1 && $x[3] eq "rst", "list bg_qx store");
ok($x[2] =~ /it is a/, "list bg_qx fetch");
delete $x[4];
ok(!defined $x[4], "list bg_qx delete");
@x = ();
ok(@x == 0, "list bg_qx clear");

### partial output ###

$t = Time();
@x = bg_qx "$^X t/external-command.pl -e=Hello -n -s=2 -e=World -s=8 -n -e=\"it is a\" -n -e=beautiful -n -e=day", { timeout => 6 };
@tests = @x;
$t = Time() - $t;
ok($tests[0] eq "Hello \n", "list bg_qx first line ok");
ok($tests[1] eq "World \n", "list bg_qx second line ok");    ### 30 ###
ok(@tests == 2, "list bg_qx interrupted output had " 
	        . scalar @tests . "==2 lines");              ### 31 ###
ok($t >= 5.5 && $t < 7.75,
	"list bg_qx took ${t}s expected ~6-7s");             ### 32 ###

sub hex_enc{join'', map {sprintf"%02x",ord} split//,shift} # for debug


__END__

exit 0;

### test variery of %options ###

$$x = 20;
my $w = 14;
$x = bg_eval {
  sleep 5; return 19
} { name => 'bg_qx_job', delay => 3, on_busy => "queue",
      callback => { queue => sub { $w++ }, start => sub { $w+=2 },
		    finish => sub { $w+=5 } }
};
$t = Time();
$j = Forks::Super::Job::get('bg_qx_job');
ok($j eq $Forks::Super::LAST_JOB, "\$Forks::Super::LAST_JOB updated");
ok($j->{state} eq "DEFERRED", "bg_qx with delay");
ok($w == 14 + 1, "bg_qx job queue callback");
Forks::Super::pause(4);
ok($j->{state} eq "ACTIVE", "bg_qx job left queue " . $j->toString());
ok($w == 14 + 1 + 2, "bg_qx start callback");
ok($$x == 19, "scalar bg_qx with lots of options");
$t = Time() - $t;
ok($t > 5.95, "bg_qx with delay took ${t}s, expected ~8s");
ok($w == 14 + 1 + 2 + 5, "bg_qx finish callback");
