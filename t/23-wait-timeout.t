use Forks::Super ':test';
use Test::More tests => 26;
use POSIX ':sys_wait_h';
use strict;
use warnings;

##################################################################
# wait(timeout)

my $t = Time();
my $pid = fork { sub => sub { sleep 2 } };
my $p = wait;
$t = Time() - $t;
ok($t >= 1.95, "wait waits for job to finish ${t}s expected ~2s");
ok($p == $pid, "wait returns pid of job");

$t = Time();
$pid = fork { sub => sub { sleep 2 } };
$p = wait 8;
$t = Time() - $t;
ok($t >= 1.95 && $t <= 5.5,            ### 3 ### was 2.85 obs 3.14,3.16,3.93
   "wait with long timeout returned when job finished ${t}s expected ~2s");
ok($p == $pid, "wait with long timeout returns pid of job $p==$pid");
$p = wait 4;
ok($p == -1, "wait returns $p==-1 when nothing to wait for");

$t = Time();
$pid = fork { sub => sub { sleep 4 } };
my $t2 = Time();
$p = wait 2;
my $t3 = Time();
($t,$t2) = ($t3-$t,$t3-$t2);
$t = Time();
ok($t2 >= 1.95 && $t2 <= 2.85,        ### 6 ###
   "wait with short timeout returns at end of timeout ${t}s ${t2}s "
   . "expected ~2s");
ok($p == Forks::Super::Wait::TIMEOUT, "wait timeout returns TIMEOUT");
$t2 = Time();
$p = wait 5;
$t3 = Time();
($t,$t2) = ($t3 - $t,$t3 - $t2);
ok($t2 >= 1.5 && $t <= 3.15,           ### 8 ### was 2.85, obs 3.08
   "subsequent wait with long timeout returned when job finished "
   . "in ${t2}s ${t}s, expected ~2s");
ok($p == $pid, "wait with subsequent long timeout returns pid of job");

##################################################################
# waitpid(target,flags,timeout)

$t = Time();
$pid = fork { sub => sub { sleep 2 } };
my $u = Time();
$p = waitpid $pid, 0, 6;
my $h = Time();
($t,$u) = ($h-$t,$h-$u);
ok($t >= 1.95 && $u <= 3.85,      ### 10 ### was 3.0 obs 3.12,3.28
   "waitpid with long timeout returns when job finishes ${t}s ${u}s "
   . "expected ~2s"); 
ok($p == $pid, "waitpid returns pid on long timeout");
$t = Time();
$p = waitpid $pid, 0, 4;
$t = Time() - $t;
ok($t <= 1, "waitpid fast return ${t}s, expected <=1s");
ok($p == -1, "waitpid -1 when nothing to wait for");

$t = Time();
$pid = fork { sub => sub { sleep 4 } };
$u = Time();
$p = waitpid $pid, 0, 2;
$h = Time();
($t,$u) = ($h-$t,$h-$u);
ok($u >= 1.95 && $u <= 2.85,             ### 14 ###
   "waitpid short timeout returns at end of timeout ${t}s ${u}s expected ~2s");
ok($p == Forks::Super::Wait::TIMEOUT, "waitpid short timeout returns TIMEOUT");

$t = Time();
$p = waitpid $pid, WNOHANG, 2;
$t = Time() - $t;
ok($t <= 1, "waitpid no hang fast return took ${t}s, expected <=1s");
ok($p == -1, "waitpid no hang returns -1");

$t = Time();
$p = waitpid $pid, 0, 4;
$t = Time() - $t;
ok($t >= 1.5 && $t <= 3.35,              ### 18 ### was 2.85 obs 3.30
   "subsequent waitpid long timeout returned when job finished "
   ."${t}s expected ~2s");
ok($p == $pid, "subsequent waitpid long timeout returned pid");

##################################################################
# waitall(timeout)

waitall;
$Forks::Super::MAX_PROC = 3;
$Forks::Super::ON_BUSY = "queue";

my $callbacks = {};
#$callbacks = { queue => sub { print Forks::Super::Util::Ctime(), " job queued\n" },
#	       start => sub { print Forks::Super::Util::Ctime(), " job started\n" },
#	       finish => sub { print Forks::Super::Util::Ctime(), " job finished\n" } };


my $t4 = Time();
my $p2 = fork { sub => sub { sleep 1 }, 
		callback => $callbacks };    # should take 1s
my $p1 = fork { sub => sub { sleep 6 }, 
		callback => $callbacks };    # should take 6s
my $p3 = fork { sub => sub { sleep 1 }, 
		callback => $callbacks };    # should take 1s
my $p4 = fork { sub => sub { sleep 10 } };   # should take 1s+10s
my $t5 = 0.5 * ($t4 + Time());


$t = Time();
my $count = waitall 3.5 + ($t5 - $t);
$t = Time() - $t5;
ok($count == 2, "waitall reaped $count==2 processes after 2 sec"); ### 20 ###
ok($t >= 3.33 && $t <= 4.05, "waitall respected timeout ${t}s expected ~3s");

$t = Time();
$count = waitall 5 + ($t5 - $t);
$t = Time() - $t5;
ok($count == 0, "waitall reaped $count==0 processes in next 1 sec"); ### 22 ###
ok($t >= 4.85 && $t <= 6.25,                ### 23 ### was 5.25 obs 
   "waitall respected timeout ${t}s expected ~5s");

$t = Time();
$count = waitall 8 + ($t5 - $t);
$t = Time() - $t5;
ok($count == 1,                             ### 24 ###
   "waitall reaped $count==1 process in next 3 sec t=$t");
ok($t >= 7.83 && $t <= 10.15,               ### 25 ### was 8.55 obs 8.56
   "waitall respected timeout ${t}s expected ~8s");

$t = Time();
$count = waitall 14 + ($t5 - $t);
$t4 = Time();
$t = $t4 - $t;
$t5 = $t4 - $t5;
ok($count == 1, Forks::Super::Util::Ctime() ### 26 ###
   ." waitall reaped $count==1 process in next 2 sec t=$t,$t5");
# ok($t5 < 13.5);
