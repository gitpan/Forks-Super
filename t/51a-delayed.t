use Forks::Super ':test';
use Test::More tests => 9;
use strict;
use warnings;

#
# test that "delay" and "start_after" options are
# respected by the fork() call. Delayed jobs should
# go directly to the job queue.
#

our $TOL = $Forks::Super::SysInfo::TIME_HIRES_TOL || 0.0;

$Forks::Super::ON_BUSY = "block";

my $now = Time::HiRes::time();
my $future = Time::HiRes::time() + 10;

my $p1 = fork { sub => sub { sleep 3 } , delay => 5 };
my $p2 = fork { sub => sub { sleep 3 } , start_after => $future };
ok($p1 < -10000, "fork to queue");
ok($p2 < -10000, "fork to queue");
my $j1 = Forks::Super::Job::get($p1);
my $j2 = Forks::Super::Job::get($p2);
ok($j1->{state} eq "DEFERRED", "deferred job has DEFERRED state");
ok($j2->{state} eq "DEFERRED", "deferred job has DEFERRED state");
ok(!defined $j1->{start}, "deferred job has not started");
waitall;
ok($j1->{start} + $TOL >= $now + 5,
   "deferred job started after delay");
ok($j2->{start} + $TOL >= $future, 
   "deferred job started after delay");
ok($j1->{start} - $j1->{created} >= 5 - $TOL,
   "job start time after creation time");
my $j2_diff = $j2->{start} - $j2->{created};
ok($j2_diff + $TOL >= 8.95,                     ### 9 ###
   "j2 took ${j2_diff}s between creation/start, expected 10s diff");

