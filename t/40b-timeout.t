use Forks::Super ':test';
use Test::More tests => 3;
use Carp;
use strict;
use warnings;

# force loading of more modules in parent proc
# so fast fail (see test#17, test#8) isn't slowed
# down so much
Forks::Super::Job::Timeout::warm_up();

#
# test that jobs respect deadlines for jobs to
# complete when the jobs specify "timeout" or
# "expiration" options
#

if (!Forks::Super::CONFIG("alarm")) {
 SKIP: {
    skip "alarm function unavailable on this system ($^O,$]), "
      . "can't test timeout feature", 3;
  }
  exit 0;
}

#######################################################

my $u = Forks::Super::Util::Time();
my $pid = fork { sub => sub { sleep 5; exit 0 }, timeout => 10 };
my $t = Forks::Super::Util::Time();
my $p = wait;
my $v = Forks::Super::Util::Time();
($t,$u)=($v-$t,$v-$u);
ok($p == $pid, "wait successful; Expected $pid got $p");
ok($t > 3.9 && $u <= 7.5,                 ### 2b ### was 7, obs 7.03
   "job completed before timeout ${t}s ${u} expected ~5s");
ok($? == 0, "job completed with zero exit status");

#######################################################