use Forks::Super qw(:test overload);
use Forks::Super::Util qw(is_socket is_pipe);
use Test::More tests => 20;
use strict;
use warnings;

Forks::Super::Debug::_use_Carp_Always();

$Forks::Super::SOCKET_READ_TIMEOUT = 0.25;

# test blocked and unblocked reading for file handles.

my $pid = fork {
  child_fh => "out,err",
  sub => sub {
    print STDERR "foo\n";
    sleep 5;
    print STDOUT "bar\n";
    sleep 5;
    print STDOUT "baz\n";
    exit 0 unless Forks::Super::Util::is_socket(*STDOUT);
  }
};

ok(isValidPid($pid), "$pid is valid pid");
SKIP: {
  if (Forks::Super::Config::CONFIG('filehandles') == 0) {
    skip "filehandles are unconfigured, ignore handle type test", 1;
  } else {
    ok(!is_socket($pid->{child_stdout}) && !is_pipe($pid->{child_stdout}), 
       "ipc with filehandles");
  }
}
sleep 1;
my $t0 = Time::HiRes::time();
my $err = Forks::Super::read_stderr($pid, "block" => 1);
my $t1 = Time::HiRes::time() - $t0;
ok($err =~ /^foo/, "read stderr");
ok($t1 <= 1.0, "read blocked stderr fast ${t1}s, expected <1s");

my $out = Forks::Super::read_stdout($pid, "block" => 1);
my $t2 = Time::HiRes::time() - $t0;
ok($out =~ /^bar/, "read stdout");
ok($t2 > 2.95, "read blocked stdout ${t2}s, expected ~4s");

$out = Forks::Super::read_stdout($pid, "block" => 0);
my $t3 = Time::HiRes::time() - $t0;
my $t32 = $t3 - $t2;
ok(!defined($out) || (defined($out) && $out eq ''), 
   "non-blocking read on stdout returned empty");
ok($t32 <= 1.0, "non-blocking read took ${t32}s, "
	      . "expected ~${Forks::Super::SOCKET_READ_TIMEOUT}s");

$out = Forks::Super::read_stdout($pid, "block" => 1);
my $t4 = Time::HiRes::time() - $t0;
my $t43 = $t4 - $t3;
ok($out =~ /^baz/, "successful blocking read on stdout");
ok($t43 > 3.5, "read blocked stdout ${t43}s, expected ~5s");

#### no more input on STDOUT or STDERR

$err = Forks::Super::read_stderr($pid, "block" => 1);
my $t5 = Time::HiRes::time() - $t0;
my $t54 = $t5 - $t4;
ok(!defined($err), "blocking read on empty stderr returns empty");
ok($t54 <= 5.0,                                       ### 12 ###
   "blocking read on empty stderr can take a moment ${t54}s, expected ~3s");

# print "\$err = $err, time = $t5, $t54\n";

$out = Forks::Super::read_stdout($pid, "block" => 0);
my $t6 = Time::HiRes::time() - $t0;
my $t65 = $t6 - $t5;
ok(!defined($out), "non-blocking read on empty stdout returns empty");
ok($t65 <= 1.3, 
   "non-blocking read on empty stdout fast ${t65}s, expected <1.0s");


# read_stdXXX with timeout

$pid = fork {
  child_fh => "out,err",
  sub => sub {
    print STDERR "foo\n";
    sleep 5;
    print STDOUT "bar\n";
    sleep 5;
    print STDOUT "baz\n";
    exit 5;
  }
};
my $x = $pid->read_stderr(timeout => 1);
ok($x, "read avail stderr with timeout");
$x = $pid->read_stdout(timeout => 2);
ok(!$x, "read unavail stdout with timeout");        ### 16 ###
$x = $pid->read_stdout(timeout => 5);
ok($x, "read avail stdout with timeout");
$x = $pid->read_stdout(timeout => 1);
ok(!$x, "read unavail stdout with timeout");
$x = $pid->read_stdout(block => 1);
ok($x, "read stdout with block");                   ### 19 ###
$x = $pid->read_stderr();
ok(!$x, "read unavail stderr");