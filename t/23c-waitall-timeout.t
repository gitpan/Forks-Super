use Forks::Super ':test';
use Test::More tests => 7;
use POSIX ':sys_wait_h';
use strict;
use warnings;

##################################################################
# waitall(timeout)

$ENV{TEST_LENIENT} = 1 if $^O =~ /freebsd/;

$Forks::Super::MAX_PROC = 3;
$Forks::Super::ON_BUSY = "queue";

my $callbacks = {};

my $t4 = Time::HiRes::time();
my $p2 = fork { sub => sub { sleep 1 }, 
		callback => $callbacks };    # should take 1s
my $p1 = fork { sub => sub { sleep 7 }, 
		callback => $callbacks };    # should take 6s
my $p3 = fork { sub => sub { sleep 1 }, 
		callback => $callbacks };    # should take 1s
my $p4 = fork { sub => sub { sleep 15 } };   # should take 1s+15s
my $t5 = 0.5 * ($t4 + Time::HiRes::time());
if ($t5 > $t4 + 1) {
    diag("took ", 2*($t5-$t4), "s to make 4 fork() calls");
}


my $t = Time::HiRes::time();
my $count = waitall 3.5 + ($t5 - $t);
$t = Time::HiRes::time() - $t5;
ok($count == 2, "waitall reaped $count==2 processes after 2 sec"); ### 1 ###
okl($t >= 3.33 && $t <= 4.5, "waitall respected timeout ${t}s expected ~3.5s");

$t = Time::HiRes::time();
$count = waitall 5 + ($t5 - $t);
$t = Time::HiRes::time() - $t5;
okl($count == 0, "waitall reaped $count==0 processes in next 1 sec") ### 3 ###
    or diag("t is ${t}s, should be ~5");
okl($t >= 4.85 && $t <= 7.25,                ### 4 ### was 5.25 obs 7.01
   "waitall respected timeout ${t}s expected ~5s");

$t = Time::HiRes::time();
$count = waitall 10 + ($t5 - $t);
$t = Time::HiRes::time() - $t5;
# common failure point on freebsd -- $count is 0 here, and 2 for test #7
ok($count == 1,                              ### 5 ###
   "waitall reaped $count==1 process in next 3 sec t=$t");
okl($t >= 8.65 && $t <= 12.8,                ### 6 ### was 8.55 obs 8.56.10.77
   "waitall respected timeout ${t}s expected ~10s");

$t = Time::HiRes::time();
$count = waitall;
$t4 = Time::HiRes::time();
$t = $t4 - $t;
$t5 = $t4 - $t5;
ok($count == 1, Forks::Super::Util::Ctime()  ### 7 ###
   ." waitall reaped $count==1 final process");
# ok($t5 < 13.5);
