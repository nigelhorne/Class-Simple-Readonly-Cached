package Class::Simple::Readonly::Cached;

use strict;
use warnings;
use autodie qw(:all);

use Carp;
use List::Util   qw(none);
use Scalar::Util qw(blessed);
use Class::Simple;
use Data::Reuse;
use Params::Get 0.15;
use Readonly;

# Private-sub enforcement: _name subs croak if called from outside this
# package.  Sub::Private respects $ENV{HARNESS_ACTIVE}, so white-box tests
# (run under prove / make test) are automatically exempt.
BEGIN { $Sub::Private::config{mode} = 'enforce' }
use Sub::Private 0.05;

# @ISA is intentionally EMPTY.
#
# Class::Simple creates permanent named methods in its own namespace the
# first time any accessor is called (e.g. the first $obj->val() call
# installs a real Class::Simple::val sub).  If we set @ISA = ('Class::Simple'),
# those installed methods would be found by Perl's normal method lookup on
# CSRC objects and would bypass our AUTOLOAD -- breaking the cache entirely.
#
# Keeping @ISA empty ensures every method call on a CSRC object is handled
# by our AUTOLOAD.  The isa() and can() overrides below restore correct
# UNIVERSAL behaviour for isa-of-Class::Simple checks.
our @ISA = ();

# Package-level registry mapping inner-object refs (stringified) to a
# record of { object => $wrapper, file => ..., line => ... }.
# Used to detect and warn about double-wrapping.
our %cached;

# Stored in the cache wherever a method returned undef or an empty list,
# so we can distinguish "not yet cached" from "cached-undef".
Readonly::Scalar my $UNDEF_SENTINEL => __PACKAGE__ . '>UNDEF<';

# CHI expiry value meaning "never expire this entry".
Readonly::Scalar my $CHI_NEVER => 'never';

=head1 NAME

Class::Simple::Readonly::Cached - cache messages to an object

=head1 VERSION

Version 0.12

=cut

our $VERSION = '0.12';

=head1 SYNOPSIS

A caching decorator for L<Class::Simple>-based (and arbitrary) objects.

It is up to the caller to maintain the cache if the object comes out of
sync with the cache, for example by changing its state.

    use Class::Simple::Readonly::Cached;

    my $obj = Class::Simple->new();
    $obj->val('foo');
    my $cached = Class::Simple::Readonly::Cached->new(
        object => $obj,
        cache  => {},
    );

    my $val  = $cached->val();   # calls the real object
    my $val2 = $cached->val();   # served from cache

    $val = $cached->val(a => 'b');   # args form part of the cache key

Note that when the object goes out of scope (DESTROY is called), the
cache is cleared automatically.

=head1 DESCRIPTION

Wraps any Perl object in a transparent caching layer.  Every method call
is intercepted via AUTOLOAD; on the first call (a I<miss>) the result is
stored in the cache and returned.  Subsequent identical calls (same method
name, same argument list) are I<hits> and are served directly from the
cache without touching the inner object.

Two cache backends are supported: a plain hash reference (fast, in-process,
no expiry) and any CHI-compatible object (persistent, shared, with expiry).

=head1 SUBROUTINES/METHODS

=head2 new

=head3 Purpose

Construct a caching proxy around any Perl object.

=head3 Arguments

=over 4

=item C<cache> (mandatory)

Either a plain hash reference (C<{}>) or a CHI-compatible object that
implements C<get()>, C<set()>, and C<purge()>.

=item C<object> (optional)

The object to wrap.  Defaults to a bare L<Class::Simple> instance.
Must be a reference; a plain scalar argument causes a C<carp> and an
C<undef> return.  Wrapping an already-wrapped
C<Class::Simple::Readonly::Cached> object returns the existing wrapper
with a warning.

=item C<quiet> (optional, boolean)

Suppress the double-wrap warning when non-zero.

=back

=head3 Returns

A C<Class::Simple::Readonly::Cached> object, or C<undef> on invalid
C<object>.  Croaks on invalid C<cache>.

=head3 EXAMPLE

    use CHI;
    use Class::Simple::Readonly::Cached;

    # --- Hash-ref cache (in-process, no expiry) ---
    my $obj    = My::Expensive->new();
    my $cached = Class::Simple::Readonly::Cached->new(
        object => $obj,
        cache  => {},
    );
    my $result  = $cached->compute();   # calls the real object
    my $result2 = $cached->compute();   # from cache -- object not called

    # --- CHI cache (persistent, file-based) ---
    my $chi = CHI->new(driver => 'File', root_dir => '/tmp/my-cache');
    my $cached2 = Class::Simple::Readonly::Cached->new(
        object => $obj,
        cache  => $chi,
    );

    # --- Clone an existing wrapper ---
    my $clone = $cached->new();   # shares the same inner object and cache

=head3 API SPECIFICATION

    # Input
    {
        cache  => { type => ['hashref', 'object'], required => 1  },
        object => { type => 'ref',                 optional => 1  },
        quiet  => { type => 'bool',                optional => 1  },
    }

    # Output
    { type => 'object', class => 'Class::Simple::Readonly::Cached',
      optional => 1 }

=head3 MESSAGES

    Message                                                 Meaning                              Resolution
    -------                                                 -------                              ----------
    Cache must be ref to HASH or object                     cache is not a hashref or blessed    Pass \%hash or a CHI object.
                                                            object
    Cache object must implement get(), set(), and purge()   blessed cache lacks required API      Use a CHI-compatible object.
    $object must be a reference, not a scalar               object is a plain string             Pass a blessed reference.
    warning: $object is already a cached object             wrapping an already-wrapped object   Reuse the returned wrapper.
    $object is already cached at LINE of FILE               double-wrap detected                 Reuse the existing wrapper;
                                                                                                 set quiet => 1 to silence.

=head3 PSEUDOCODE

    1.  If class is undef:           carp and return undef   (::new() misuse)
    2.  If class is blessed:         merge params into a clone and return
    3.  Validate cache:              croak if not a hashref or CHI-compatible object
    4.  Validate object:             carp+return if scalar; return existing
                                     wrapper if already __PACKAGE__
    5.  Create inner object:         Class::Simple->new(non-wrapper params)
                                     unless object was supplied
    6.  Check double-wrap registry:  if object in %cached, carp and return
                                     existing wrapper (unless quiet)
    7.  Bless and register:          bless $params, $class; store in %cached
                                     with caller file and line
    8.  Return $self

=cut

sub new
{
	my $class = shift;

	# Guard against the common mistake of calling ::new() instead of ->new().
	if(!defined($class)) {
		Carp::carp(__PACKAGE__ . ': use ->new() not ::new() to instantiate');
		return;
	}

	# Object invocation: clone the existing wrapper, merging any new params.
	if(blessed($class)) {
		my $params = Params::Get::get_params(undef, \@_) // {};
		my $clone  = bless { %{$class}, %{$params} }, ref($class);
		# If the caller overrides the cache, rebuild the pre-computed dispatch
		# closures so they target the new backend, not the original one.
		if(exists $params->{cache}) {
			_build_cache_accessors($clone);
		}
		return $clone;
	}

	my $params = Params::Get::get_params('cache', @_);

	# Validate the cache argument before doing anything else.
	if(blessed($params->{cache})) {
		unless($params->{cache}->can('get')
			&& $params->{cache}->can('set')
			&& $params->{cache}->can('purge'))
		{
			Carp::croak("$class: Cache object must implement get(), set(), and purge()");
		}
	} elsif(ref($params->{cache}) ne 'HASH') {
		Carp::croak("$class: Cache must be ref to HASH or object");
	}

	if(defined($params->{object})) {
		if(!ref($params->{object})) {
			Carp::carp(__PACKAGE__ . ': $object must be a reference, not a scalar');
			return;
		}
		if(ref($params->{object}) eq __PACKAGE__) {
			# Silently returning the existing wrapper is safer than building
			# a second layer that would double-count misses/hits.
			Carp::carp(__PACKAGE__ . ': warning: $object is already a cached object');
			return $params->{object};
		}
	} else {
		# No inner object supplied: create a bare Class::Simple instance.
		# Forward only non-wrapper keys so that 'cache' and 'quiet' do not
		# bleed into the inner object's attribute hash.
		my %inner = %{$params};
		delete @inner{qw(cache quiet)};   # O(1) hash-slice delete, no temp list
		$params->{object} = Class::Simple->new(%inner);
	}

	# Warn if this inner object is already wrapped in a cache -- returning the
	# existing wrapper prevents hidden double-caching with stale hit counts.
	if(my $existing = $cached{$params->{object}}) {
		unless($params->{quiet}) {
			Carp::carp(__PACKAGE__ . ' $object is already cached at '
				. $existing->{line} . ' of ' . $existing->{file});
		}
		return $existing->{object};
	}

	my $self = bless $params, $class;

	# Pre-compute values used on every AUTOLOAD dispatch.
	$self->{_class} = $class;
	_build_cache_accessors($self);

	my (undef, $file, $line) = caller(0);   # destructure: only fields 1 and 2 needed
	$cached{$self->{object}} = {
		object => $self,
		file   => $file,
		line   => $line,
	};

	return $self;
}

=head2 object

=head3 Purpose

Return the inner (wrapped) object.

=head3 Returns

The blessed reference that was passed as C<object> to C<new()>.

=head3 EXAMPLE

    # Bypass the cache to mutate state directly.
    $cached->object()->reset();

=head3 API SPECIFICATION

    # Input  none
    # Output { type => 'object' }

=head3 MESSAGES

    (none)

=cut

sub object
{
	return $_[0]->{object};
}

=head2 state

=head3 Purpose

Return a snapshot of cache hit and miss counts per cache key.
Primarily useful for performance profiling and white-box tests.

=head3 Returns

A hash reference:

=over 4

=item C<hits>

Hash reference mapping each cache key to the number of times the
result was served from cache.  C<undef> until the first hit.

=item C<misses>

Hash reference mapping each cache key to the number of times the
inner object was actually invoked.  C<undef> until the first miss.

=back

=head3 EXAMPLE

    my $s = $cached->state();
    my $hits   = do { my $n=0; $n += $_ for values %{$s->{hits}   // {}}; $n };
    my $misses = do { my $n=0; $n += $_ for values %{$s->{misses} // {}}; $n };
    printf "Hit rate: %.0f%%\n", 100 * $hits / ($hits + $misses) if $hits + $misses;

=head3 API SPECIFICATION

    # Input  None
    # Output { type => 'hashref',
    #          keys => { hits   => 'hashref|undef',
    #                    misses => 'hashref|undef' } }

=head3 MESSAGES

    (none)

=cut

sub state
{
	my $self = shift;
	return { hits => $self->{_hits}, misses => $self->{_misses} };
}

=head2 can

=head3 Purpose

Report whether the inner object (or this class) can respond to a
given method.  Overrides C<UNIVERSAL::can> to account for the
decorator pattern.

=head3 Returns

A code reference if the method exists, C<undef> otherwise.

=head3 EXAMPLE

    my $code = $cached->can('compute');
    $code->($cached) if $code;

=head3 API SPECIFICATION

    # Input  { self   => { type => 'object|string' },
    #          method => { type => 'string' } }
    # Output { type => 'coderef|undef' }

=head3 MESSAGES

    (none)

=cut

sub can
{
	my ($self, $method) = @_;
	return (
		$method eq 'new'                       ? \&new
		: !ref($self) || !ref($self->{object}) ? $self->SUPER::can($method)
		:                                         ($self->{object}->can($method) // $self->SUPER::can($method))
	);
}

=head2 isa

=head3 Purpose

Test class membership, delegating to the inner object's class
hierarchy when needed.  Overrides C<UNIVERSAL::isa> to support the
transparent decorator pattern.

=head3 Returns

True if the wrapper or its inner object is-a C<$class>.

=head3 EXAMPLE

    $cached->isa('My::Domain::Object');   # true if inner object is

=head3 API SPECIFICATION

    # Input  { self  => { type => 'object|string' },
    #          class => { type => 'string' } }
    # Output { type => 'bool' }

=head3 MESSAGES

    (none)

=cut

sub isa
{
	my ($self, $class) = @_;
	return (
		$class eq ref($self)  || $class eq __PACKAGE__
		|| $class eq 'Class::Simple' || $self->SUPER::isa($class)
			? 1
			: (ref($self) && ref($self->{object}) && $self->{object}->isa($class))
	);
}

# _build_cache_accessors -- install backend-specific _get/_set closures on $self.
# Purpose:     The cache backend (HASH vs CHI) is fixed for a wrapper's lifetime.
#              Deciding which branch to take on every AUTOLOAD call via ref($cache)
#              plus a Sub::Private caller() check is unnecessary overhead.  Instead
#              we close over the bare cache reference once at construction time and
#              expose two named slots (_get/_set) that AUTOLOAD calls directly.
#              The closures capture the cache ref as a lexical -- no reference back
#              to $self, so no circular-reference hazard.
# Entry:       $self is a fully-blessed wrapper with {cache} already set.
# Exit:        $self->{_get}, $self->{_set}, and $self->{_cache_is_hash} are set.
# Side-effects: Mutates $self.
sub _build_cache_accessors :Private
{
	my ($self) = @_;
	my $c = $self->{cache};                  # captured by the closures below
	if(ref($c) eq 'HASH') {
		$self->{_cache_is_hash} = 1;
		$self->{_get}           = sub { $c->{$_[0]}                       };
		$self->{_set}           = sub { $c->{$_[0]} = $_[1]               };
	} else {
		$self->{_cache_is_hash} = 0;
		$self->{_get}           = sub { $c->get($_[0])                     };
		$self->{_set}           = sub { $c->set($_[0], $_[1], $CHI_NEVER)  };
	}
}

# _can_fixate -- decide whether Data::Reuse::fixate is safe on a list.
# Purpose:     fixate cannot handle GLOBs or blessed objects (RT#100461,
#              RT#163955).  Only plain ARRAY, HASH, and SCALAR refs are safe.
# Entry:       @_ is the list of values returned by the wrapped method.
# Exit:        Returns 1 (safe) or 0 (unsafe).
# Side-effects: none.
sub _can_fixate :Private
{
	return none {
		my $r = ref($_);
		$r && $r !~ /\A (?:ARRAY|HASH|SCALAR) \z/x   # GLOBs and blessed refs are unsafe for fixate
	} @_;
}

=head2 AUTOLOAD

Not called directly.  Intercepts all method calls not defined
explicitly in this package, proxies them to the inner object, and
caches the results.

Handles C<DESTROY> specially: removes the wrapper from the
double-wrap registry and clears cache entries whose keys begin with
the class name, before allowing normal Perl destruction to proceed.

=cut

sub AUTOLOAD
{
	our $AUTOLOAD;
	my ($method) = $AUTOLOAD =~ /::(\w+)\z/;

	my $self     = shift;
	my $cache    = $self->{cache};
	my $wantlist = wantarray;    # hoist: Perl does not cache this; avoid 3-4 redundant calls

	# DESTROY arrives here because we handle it dynamically rather than
	# defining a named sub (which would suppress Class::Simple's AUTOLOAD).
	if($method eq 'DESTROY') {
		# During global destruction the symbol table may already be torn
		# down; accessing the cache at that point is unsafe.
		return if defined($^V) && ($^V ge 'v5.14.0') && ${^GLOBAL_PHASE} eq 'DESTRUCT';

		# Remove from the double-wrap registry to prevent memory leaks in
		# long-running processes that create and destroy many wrappers.
		delete $cached{$self->{object}} if ref($self->{object});

		if($cache) {
			if($self->{_cache_is_hash}) {
				# Only delete keys that belong to this instance's class,
				# leaving entries from other classes untouched.
				my $prefix = $self->{_class};
				delete $cache->{$_} for grep { index($_, $prefix) == 0 } keys %{$cache};
			} else {
				$cache->purge();
			}
		}
		return;
	}

	# Build the cache key.
	# - _class is pre-computed in new() so we avoid ref($self) on every call.
	# - The @_ guard skips grep+join entirely for the common zero-arg getter case.
	my $key = $self->{_class} . '::' . $method . '::';
	$key .= join('::', grep { defined } @_) if @_;

	# Use the pre-built backend closures (_get/_set) rather than a runtime
	# ref($cache) branch: the backend was fixed at construction time.
	my $get = $self->{_get};
	my $set = $self->{_set};

	my $cached_val = $get->($key);
	if(defined($cached_val)) {
		if(ref($cached_val) eq 'ARRAY') {
			# The method previously returned a list; serve it in either context.
			$self->{_hits}{$key}++;
			return $wantlist ? @{$cached_val} : $cached_val->[-1];
		}
		if($cached_val eq $UNDEF_SENTINEL) {
			# The method previously returned undef or an empty list.
			$self->{_hits}{$key}++;
			return;
		}
		if(!$wantlist) {
			# Scalar hit in scalar context.
			$self->{_hits}{$key}++;
			return $cached_val;
		}
		# A scalar is cached but the caller now wants a list.  Fall through
		# to re-invoke the method in list context and cache the array result.
		# This is not counted as a hit because we could not serve it from cache.
	}

	$self->{_misses}{$key}++;
	my $object = $self->{object};

	if($wantlist) {
		my @result = $object->$method(@_);
		if(!@result) {
			$set->($key, $UNDEF_SENTINEL);
			return;
		}
		# Share identical string values between cache entries to reduce memory
		# usage.  Skip if any element is a type that fixate cannot handle safely.
		Data::Reuse::fixate(@result) if _can_fixate(@result);
		$set->($key, \@result);
		return @result;
	}

	my $result = $object->$method(@_);
	if(!defined($result)) {
		$set->($key, $UNDEF_SENTINEL);
		return;
	}
	$set->($key, $result);
	return $result;
}

=head1 LIMITATIONS

=over 4

=item B<Not safe for mutable objects>

The cache is never invalidated automatically.  If the inner object's
state changes after caching, the wrapper will return stale data.  The
caller must either reset the cache manually or avoid using this module
with objects that mutate.

=item B<Argument serialisation is naive>

Cache keys are built by joining defined arguments with C<::>.  Two
different argument lists can therefore produce the same key if an
argument itself contains C<::> (e.g. C<foo('a::b', 'c')> vs
C<foo('a', 'b::c')>).  Callers that pass arguments containing C<::>
should use a CHI backend with a custom key serialiser.

=item B<Undefined arguments are collapsed>

Undefined values in the argument list are silently dropped from the
cache key, so C<foo(undef)> and C<foo()> share a cache entry.

=item B<Scalar-then-list context mismatch is a miss>

If a method is first called in scalar context and then in list
context with identical arguments, the second call is a cache miss
and re-invokes the inner object.  Both results are then independently
cached.

=item B<C<can('new')> returns a code reference, not a boolean>

For strict correctness C<can> returns C<\&new> for the C<'new'>
method rather than the boolean C<1>.  The code reference is callable
but callers who compare it with C<==> to C<1> will see a mismatch.

=item B<Does not work with L<Memoize>>

C<Memoize> intercepts at the symbol-table level and conflicts with
the C<AUTOLOAD> dispatch used here.

=back

=head1 AUTHOR

Nigel Horne, C<< <njh at nigelhorne.com> >>

=head1 BUGS

Please report any bugs or feature requests to
L<https://github.com/nigelhorne/Class-Simple-Readonly-Cached/issues>.

=head1 SEE ALSO

=over 4

=item * L<Test Dashboard|https://nigelhorne.github.io/Class-Simple-Readonly-Cached/coverage/>

=item * L<Class::Simple>

=item * L<CHI>

=item * L<Data::Reuse>

Values are shared between C<Class::Simple::Readonly::Cached> objects,
since they are read-only.

=item * L<constant::defer>

=back

=head1 SUPPORT

This module is provided as-is without any warranty.

You can find documentation for this module with the perldoc command.

    perldoc Class::Simple::Readonly::Cached

=over 4

=item * MetaCPAN

L<https://metacpan.org/release/Class-Simple-Readonly-Cached>

=item * Source Repository

L<https://github.com/nigelhorne/Class-Simple-Readonly-Cached>

=item * CPAN Testers

L<http://matrix.cpantesters.org/?dist=Class-Simple-Readonly-Cached>

=back

=head1 FORMAL SPECIFICATION

=head2 new

    new : (C x P) -> (W | undef)

    C = class name string
    P = { cache : (HashRef | CacheObj), object? : Ref, quiet? : Bool, ... }
    W = blessed P in C

    valid_cache(c) :=
        ref(c) = 'HASH'
        OR ( blessed(c) AND c.can('get') AND c.can('set') AND c.can('purge') )

    Precondition:
        valid_cache(P.cache)

    Double-wrap invariant:
        forall o in Dom(cached): new(C, {object: o, ...}) = cached[o].object

    Clone (object invocation):
        forall w : W: w.new(P') = bless( merge(w, P'), ref(w) )

=head2 object

    object : W -> Ref

    forall w : W: object(w) = w.object

=head2 state

    state : W -> HashRef

    forall w : W: state(w) = { hits => w._hits, misses => w._misses }

=head2 can

    can : (W|Str x Str) -> (CodeRef | undef)

    forall w : W, m : Str:
      can(w, 'new') = \&new
      can(w, m)     = w.object.can(m)  OR SUPER::can(w, m)

=head2 isa

    isa : (W x Str) -> Bool

    forall w : W, c : Str:
      isa(w, c) = 1  if c in { ref(w), 'Class::Simple::Readonly::Cached' }
               | 1  if SUPER::isa(w, c)
               | w.object.isa(c)  if ref(w)
               | 0  otherwise

=head2 autoload

    autoload : (W x M x A*) -> R

    M  = method name string
    A* = argument tuple (possibly empty)
    R  = scalar | list | undef

    Cache key:
        k(w, m, a) := w._class ++ '::' ++ m ++ '::' ++ defined_args(a)
        (w._class = ref(w), pre-computed once in new() to avoid ref() per dispatch)

    Caching law:
        get(cache(w), k(w,m,a)) = v, v != undef
            => autoload(w, m, a) = v          (cache hit)
        get(cache(w), k(w,m,a)) = undef
            => v = w.object.m(a)
               set(cache(w), k(w,m,a), v)
               autoload(w, m, a) = v          (cache miss)

=head1 LICENSE AND COPYRIGHT

Author Nigel Horne: C<njh@nigelhorne.com>
Copyright (C) 2019-2026 Nigel Horne

Usage is subject to the GPL2 licence terms.
If you use it,
please let me know.

=cut

1;
