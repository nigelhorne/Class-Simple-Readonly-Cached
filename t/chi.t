#!perl -wT

use strict;
use warnings;
use Test::Most tests => 36;
use Test::NoWarnings;
use CHI;

BEGIN {
	use_ok('Class::Simple::Readonly::Cached');
}

CHI: {
	my $cache = CHI->new(driver => 'RawMemory', global => 1);
	$cache->on_set_error('die');
	$cache->on_get_error('die');
	my $l = new_ok('Class::Simple::Readonly::Cached' => [ cache => $cache, object => x->new() ]);

	ok($l->calls() == 0);
	ok($l->barney('betty') eq 'betty');
	ok($l->calls() == 1);
	ok($l->barney() eq 'betty');
	ok($l->calls() == 1);
	ok($l->barney() eq 'betty');
	ok($l->calls() == 1);
	my @abc = $l->abc();
	ok(scalar(@abc) == 3);
	ok($abc[0] eq 'a');
	ok($abc[1] eq 'b');
	ok($abc[2] eq 'c');
	@abc = $l->abc();
	ok(scalar(@abc) == 3);
	ok($abc[0] eq 'a');
	ok($abc[1] eq 'b');
	ok($abc[2] eq 'c');
	my @a = $l->a();
	ok(scalar(@a) == 1);
	ok($a[0] eq 'a');
	@a = $l->a();
	ok(scalar(@a) == 1);
	ok($a[0] eq 'a');

	ok($l->echo('foo') eq 'foo');
	ok($l->echo('foo') eq 'foo');
	ok($l->echo('bar') eq 'bar');
	ok($l->echo('bar') eq 'bar');
	ok($l->echo('foo') eq 'foo');

	my @empty = $l->empty();
	ok(scalar(@empty) == 0);

	ok(!defined($l->empty()));
	ok(!defined($l->empty()));

	# White box test the cache
	ok($cache->get('barney::') eq 'betty');
	ok($cache->get('barney::betty') eq 'betty');
	ok($cache->get('echo::foo') eq 'foo');
	ok($cache->get('echo::bar') eq 'bar');
	my $a = $cache->get('a::');
	ok(ref($a) eq 'ARRAY');
	my $abc = $cache->get('abc::');
	ok(ref($abc) eq 'ARRAY');

	# foreach my $key($cache->get_keys()) {
		# diag($key);
	# }
}

package x;

sub new {
	my $proto = shift;

	my $class = ref($proto) || $proto;

	return bless { calls => 0 }, $class;
}

sub barney {
	my $self = shift;
	my $param = shift;

	$self->{'calls'}++;
	return 'betty';
}

sub abc {
	return ('a', 'b', 'c');
}

sub a {
	return 'a';
}

sub empty {
}

sub echo {
	my $self = shift;

	if(wantarray) {
		return @_;
	}

	return $_[0];
}

sub calls {
	my $self = shift;

	return $self->{'calls'};
}

1;