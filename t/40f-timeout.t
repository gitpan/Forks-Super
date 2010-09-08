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

SKIP: {
  if (!Forks::Super::CONFIG("alarm")) {
    skip "alarm function unavailable on this system ($^O,$]), "
      . "can't test timeout feature", 3;
  }

#######################################################

my $future = Time::HiRes::gettimeofday() - 5;
my $pid = fork { sub => sub { sleep 5; exit 0 }, expiration => $future };
my $t = Time::HiRes::gettimeofday();
my $p = wait;
$t = Time::HiRes::gettimeofday() - $t;
ok($p == $pid, "wait succeeded");
# A "fast fail" can still take longer than a second. 
# "fast fail" invokes Carp::croak, which wants to load
# Carp::Heavy, Scalar::Util, List::Util, List::Util::XS.
# That can add up.
#ok($t <= 1.0, "expected fast fail took ${t}s"); ### 17 ###
ok($t <= 1.9, "expected fast fail took ${t}s"); ### 17 ###
ok($? != 0, "job expired with non-zero exit STATUS");

#######################################################

} # end SKIP
