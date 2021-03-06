use Forks::Super ':test';
use Test::More tests => 24;
use strict;
use warnings;

ok(!defined $Forks::Super::LAST_JOB, 
   "$$\\\$Forks::Super::LAST_JOB not set");
ok(!defined $Forks::Super::LAST_JOB_ID, 
   "\$Forks::Super::LAST_JOB_ID not set");

delete $Forks::Super::Config::CONFIG{"JSON"};
$Forks::Super::Config::CONFIG{"YAML"} = 0;

SKIP: {
    if ($ENV{NO_JSON}) {
	skip "NO_JSON specified, skipping bg_eval tests", 22;
    }
    if (!Forks::Super::Config::CONFIG_module("JSON")) {
	skip "JSON module not available, skipping bg_eval tests", 22;
    }

    require "./t/62a-bg_eval.tt";
}
