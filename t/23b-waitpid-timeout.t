use Forks::Super ':test';
use Test::More tests => 22;
use POSIX ':sys_wait_h';
use strict;
use warnings;

##################################################################
# waitpid(target,flags,timeout)

my $t = Time::HiRes::time();
my $pid = fork { sub => sub { sleep 2 } };
my $u = Time::HiRes::time();
my $p = waitpid $pid, 0, 6;
my $h = Time::HiRes::time();
($t,$u) = ($h-$t,$h-$u);
okl($t >= 1.95 && $u <= 5.25,      ### 10 ### was 3.0 obs 3.12,3.28,3.95
   "waitpid with long timeout returns when job finishes ${t}s ${u}s "
   . "expected ~2s"); 
ok($p == $pid, "waitpid returns pid on long timeout");
$t = Time::HiRes::time();
$p = waitpid $pid, 0, 4;
$t = Time::HiRes::time() - $t;
okl($t <= 1, "waitpid fast return ${t}s, expected <=1s");
ok($p == -1, "waitpid -1 when nothing to wait for");

$t = Time::HiRes::time();
$pid = fork { sub => sub { sleep 4 } };
$u = Time::HiRes::time();
$p = waitpid $pid, 0, 2;
$h = Time::HiRes::time();
($t,$u) = ($h-$t,$h-$u);
okl($u >= 1.95 && $u <= 3.05,             ### 14 ###
   "waitpid short timeout returns at end of timeout ${t}s ${u}s expected ~2s");
ok($p == &Forks::Super::Wait::TIMEOUT, 
   "waitpid short timeout returns TIMEOUT");

$t = Time::HiRes::time();
$p = waitpid $pid, WNOHANG, 2;
$t = Time::HiRes::time() - $t;
okl($t <= 1, "waitpid no hang fast return took ${t}s, expected <=1s");

# XXX waitpid WNOHANG should return 0 or -1 for active process???
ok($p == -1 || $p == 0, "waitpid no hang returns -1");

$t = Time::HiRes::time();
$p = waitpid $pid, 0, 10;
$t = Time::HiRes::time() - $t;
okl($t >= 1.01 && $t <= 4.15,              ### 18 ### was 2.85 obs 3.30,4.12
   "subsequent waitpid long timeout returned when job finished "
   ."${t}s expected ~2s");
ok($p == $pid, "subsequent waitpid long timeout returned pid");

# waitall;

##################################################################

# exercise OO-style  $pid->waitpid,  $pid->wait

$t = Time::HiRes::time();
$pid = fork { sub => sub { sleep 2 } };
$u = Time::HiRes::time();
$p = $pid->wait(6);
$h = Time::HiRes::time();
($t,$u) = ($h-$t,$h-$u);
okl($t >= 1.95 && $u <= 5.25,
   "waitpid with long timeout returns when job finishes ${t}s ${u}s "
   . "expected ~2s"); 
ok($p == $pid, "waitpid returns pid on long timeout");
$t = Time::HiRes::time();
$p = $pid->wait(4);
$t = Time::HiRes::time() - $t;
okl($t <= 1, "waitpid fast return ${t}s, expected <=1s");
ok($p == -1, "waitpid -1 when nothing to wait for");

$t = Time::HiRes::time();
$pid = fork { sub => sub { sleep 4 } };
$u = Time::HiRes::time();
$p = $pid->waitpid(0, 2);
$h = Time::HiRes::time();
($t,$u) = ($h-$t,$h-$u);
okl($u >= 1.95 && $u <= 3.05,
   "waitpid short timeout returns at end of timeout ${t}s ${u}s expected ~2s");
ok($p == &Forks::Super::Wait::TIMEOUT, 
   "waitpid short timeout returns TIMEOUT");

$t = Time::HiRes::time();
$p = $pid->waitpid(WNOHANG, 2);
$t = Time::HiRes::time() - $t;
okl($t <= 1, "waitpid no hang fast return took ${t}s, expected <=1s");

ok($p == -1 || $p == 0, "waitpid no hang returns -1 or 0");

$t = Time::HiRes::time();
$p = $pid->wait(0);
$t = Time::HiRes::time() - $t;
okl($t <= 1, "pid->wait(0) like WNOHANG fast return took ${t}s, expected <=1s");
ok($p == -1 || $p == 0, "pid->wait(0) returns -1 or 0");

$t = Time::HiRes::time();
$p = $pid->wait;
$t = Time::HiRes::time() - $t;
okl($t >= 1.01 && $t <= 4.15,
   "pid->wait() waits for job to finish  ${t}s expected ~2s");      ### 21 ###
ok($p == $pid, "subsequent waitpid long timeout returned pid");
waitall;
