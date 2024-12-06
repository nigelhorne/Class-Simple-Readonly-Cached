#!/usr/bin/env perl

use strict;
use warnings;

use Data::Dumper;
use Test::Most tests => 16;

BEGIN { use_ok('Class::Simple::Readonly::Cached') };

# Test the 'new' constructor
my $cache = {};
my $object = Class::Simple->new();
$object->val('test_value');
my $cached_object = Class::Simple::Readonly::Cached->new(object => $object, cache => $cache);

ok($cached_object, 'Object created successfully');

# Test the object encapsulation
isa_ok($cached_object, 'Class::Simple::Readonly::Cached', 'Object is of correct class');
isa_ok($cached_object->object(), 'Class::Simple', 'Encapsulated object is of correct class');

# Test uncached values
is($cached_object->val(), 'test_value', 'Value retrieved from object matches');
is($cache->{'val::'}, 'test_value', 'Value correctly cached');

# Test state method
my $state = $cached_object->state();
ok($state, 'State method works');
diag(Data::Dumper->new([$state])->Dump()) if($ENV{'TEST_VERBOSE'});
cmp_deeply($state, { misses => { 'val::' => 1 }, hits => undef }, 'State reports hits and misses correctly after one miss');

# Test cached values
is($cached_object->val(), 'test_value', 'Value retrieved from object matches');
$state = $cached_object->state();
diag(Data::Dumper->new([$state])->Dump()) if($ENV{'TEST_VERBOSE'});
cmp_deeply($state, { misses => { 'val::' => 1 }, hits => { 'val::' => 1 } }, 'State reports hits and misses correctly after one miss and one hit');
is($cached_object->val(), 'test_value', 'Value retrieved twice from object matches');
$state = $cached_object->state();
diag(Data::Dumper->new([$state])->Dump()) if($ENV{'TEST_VERBOSE'});
cmp_deeply($state, { misses => { 'val::' => 1 }, hits => { 'val::' => 2 } }, 'State reports hits and misses correctly after one miss and two hits');

diag(Data::Dumper->new([$cache])->Dump()) if($ENV{'TEST_VERBOSE'});
cmp_deeply($cache, { 'val::' => 'test_value' }, 'White box test the cache contents');

# Test calling an uncached method
$object->val('new_value'); # Change the state of the original object
is($cached_object->val(), 'test_value', 'Cached value remains the same');
$cached_object->{'cache'}{'val::'} = undef; # Simulate cache reset
is($cached_object->val(), 'new_value', 'Updated value retrieved after cache reset');

# Test warning when caching an already cached object
{
	local $SIG{__WARN__} = sub {
		my $warn = shift;
		like($warn, qr/.*is already cached.*/, 'Warning issued for caching an already cached object');
	};
	Class::Simple::Readonly::Cached->new(object => $object, cache => $cache);
}
