# -*- mode: cperl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id$

#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# (C) Copyright Ticketmaster, Inc. 2007
#

package Spine::Data;

use strict;
use Cwd;
use File::Basename;
use File::Spec::Functions;
use IO::Dir;
use IO::File;
use Scalar::Util qw(blessed);
use Spine::Constants qw(:basic :plugin :keys);
use Spine::Registry;
use Spine::Util;
use Spine::Key;
use Spine::Resource qw(resolve_resource);
use Sys::Syslog;
####### TODO refactor this out
use Template::Exception;
#######
use UNIVERSAL;

our $VERSION = sprintf( "%d", q$Revision: 1$ =~ /(\d+)/ );

our $DEBUG = $ENV{SPINE_DATA_DEBUG} || 0;
our ( $PARSER_FILE, $PARSER_LINE, $KEYTT );

our ( $DATA_PARSED, $DATA_POPULATED ) = ( SPINE_NOTRUN, SPINE_NOTRUN );

sub new {
    my $class = shift;
    my %args  = @_;

    my $registry = new Spine::Registry();
    my $croot    = $args{croot} || $args{source}->config_root() || undef;

    unless ($croot) {
        die "No configuration root passed to Spine::Data!  Badness!";
    }

    my $data_object = bless( {  hostname    => $args{hostname},
                                c_hostname  => $args{hostname},
                                c_release   => $args{release},
                                c_verbosity => $args{verbosity} || 0,
                                c_quiet     => $args{quiet},
                                c_version   => $args{version} || $::VERSION,
                                c_config    => $args{config},
                                c_croot     => $croot, },
                             $class );

    if ( not defined( $data_object->{c_release} ) ) {
        print STDERR 'Spine::Data::new(): we require the config release '
          . 'number!';
        return undef;
    }

    $data_object->_create_hookpoints($registry);

    # XXX Right now, the driver script handles error reporting
    unless ( $data_object->_data() == SPINE_SUCCESS ) {
        $data_object->{c_failure} = 1;
    }

    return $data_object;
}

sub _create_hookpoints {
    my $self     = shift;
    my $registry = shift;

    # Let's register the hookable points we're going to be running, we don't
    # need to do this as they will be created as needed but it makes it clear
    # what we expect to use.

    # Runtime data discovery.  Basically these are keys that will show up in
    # $c(a.k.a. the "c" object in a template) that aren't parsed out of the
    # configball.  This is stuff like c_is_virtual, c_filer_exports, etc.
    $registry->create_hook_point(
        qw(DISCOVERY/populate
          DISCOVERY/policy-selection) );

    # The actual parsing of the configball
    $registry->create_hook_point(
        qw(PARSE/initialize
          PARSE/start-descent
          PARSE/pre-descent
          PARSE/key
          PARSE/post-descent
          PARSE/complete) );

    # Since we are the owner of PARSE/key we need to set up some odering rules.
    # This allow an order to be assimed with a single provide given.
    # (order bellow)
    #  -init
    #      -retrieve
    #      -markup
    #      -preprocess (PARSE/key/line)
    #  - process
    #      -complex (PARSE/key/complex)
    #      -dynamic (PARSE/key/dynamic)
    #      -simple
    #  - finalize
    #      -tidy
    #      -operate
    my $point = $registry->get_hook_point('PARSE/key');
    #### init
    # hooks the provide retrieve also provide init
    $point->add_rule( provide  => "retrieve",
                      provides => ["init"] );
    $point->add_rule( provide  => "markup",
                      provides => ["init"],
                      succedes => ["retrieve"] );
    $point->add_rule( provide  => "preprocess",
                      provides => ["init"],
                      succedes => [ "retrieve", "markup" ] );
    #### process
    # hooks that provide process come after hooks that provide init
    $point->add_rule( provide  => "process",
                      succedes => ["init"] );
    $point->add_rule( provide  => "complex",
                      provides => ["process"] );
    $point->add_rule( provide  => "dynamic",
                      provides => ["process"],
                      succedes => ["complex"] );
    $point->add_rule( provide  => "simple",
                      provides => ["process"],
                      succedes => [ "complex", "dynamic" ] );

    ### finalize
    # hooks that provide finalize come after hooks the provide init and process
    $point->add_rule( provide  => "finalize",
                      succedes => [ "init", "process" ] );
    $point->add_rule( provide  => "tidy",
                      provides => ["finalize"] );
    $point->add_rule( provide  => "merge",
                      provides => ["finalize"],
                      succedes => ["tidy"] );

}

# kick off the populate and parse sections
sub _data {
    my $self = shift;
    my $rc   = SPINE_SUCCESS;

    my $cwd = getcwd();
    chdir( $self->{c_croot} );
    $self->{c_croot} = getcwd();

    unless ( $self->populate() == SPINE_SUCCESS ) {
        $self->error( 'Failure to run populate()!', 'crit' );
        $rc = SPINE_FAILURE;
    }

    unless ( $rc != SPINE_SUCCESS ) {
        unless ( $self->parse() == SPINE_SUCCESS ) {
            $self->error( 'Failure to run parse()!', 'crit' );
            $rc = SPINE_FAILURE;
        }
    }

    chdir($cwd);
    return $rc;
}

# This does some initial bootstrapping of data and then builds out a full
# list of branches to descend
# The core of this is Spine::Plugins::DescendOrder which implements a specual
# key. It uses Spine::Plugins::Descend::* to do it's magic in a pluggable way
sub populate {
    my $self     = shift;
    my $registry = new Spine::Registry();
    my $errors   = 0;

    if ( $DATA_POPULATED != SPINE_NOTRUN ) {
        return $DATA_POPULATED;
    }

    # Some truly basic stuff first.
    $self->{c_label}      = 'spine-mgmt core';
    $self->{c_start_time} = time();
    $self->{c_ppid}       = $$;

    # FIXME  Should these be moved to Spine::Plugin::Overlay?
    $self->{c_tmpdir}  = "/tmp/spine-mgmt." . $self->{c_ppid};
    $self->{c_tmplink} = "/tmp/spine-mgmt.lastrun";


    # HOOKME  INIT
    # use this hook for anything that must be done before
    # parsing any config items. 
    my $point = $registry->get_hook_point('INIT');

    my $rc = $point->run_hooks($self);

    # Spine::Registry::HookPoint::run_hooks() returns the number of
    # errors + failures encountered by plugins
    if ( $rc != 0 ) {
        $DATA_POPULATED = SPINE_FAILURE;
        $self->error( 'INIT: Failed to run at least one hook!',
                      'crit' );
        return SPINE_FAILURE;
    }

    # Retrieve "internal" config values nesessary for bootstrapping of
    # discovery and therefore parsing of the tree.
    $self->cprint( "retrieving base settings", 3 );

    # TODO: this location should probably be based on something passed by
    #       the spine-mgmt executable, this will allow it to be alterd
    #       i.e. there is no reason why this has to be a file uri
    # XXX: this location will be processed by Spine::Plugins::Data::Disk
    $self->{c_internals_dir} = 'spine_internals';
    if ( $self->read_config_branch(uri => "file:" . $self->{c_internals_dir},
                                   fatal_if_missing => 1) != 0 )
    {
        $self->error(
               'error parsing config within "' . $self->{c_internals_dir} . '"',
               'crit' );

        # Without this nothing much will work, so rather
        # then letting the user find out by an indirectly
        # related error we stop now.
        return SPINE_FAILURE;
    }

    # TODO: this should be moved to a compatibility module
    #       and a new key spine_local_internals_uris be used insted
    my @dir_list =
      ( ref( $self->{'spine_local_internals_dirs'} ) eq 'ARRAY' )
      ? @{ $self->{'spine_local_internals_dirs'} }
      : ( $self->{'spine_local_internals_dirs'} );
    foreach my $dir (@dir_list) {
        next unless defined $dir;
        $self->read_config_branch( uri => "file:$dir",
                                   fatal_if_missing => 1 );
    }

    #
    # Begin discovery
    #

    # HOOKME  Discovery: populate
    $point = $registry->get_hook_point('DISCOVERY/populate');

    $rc = $point->run_hooks($self);

    # Spine::Registry::HookPoint::run_hooks() returns the number of
    # errors + failures encountered by plugins
    if ( $rc != 0 ) {
        $DATA_POPULATED = SPINE_FAILURE;
        $self->error( 'DISCOVERY/populate: Failed to run at least one hook!',
                      'crit' );
        return SPINE_FAILURE;
    }

    # FIXME: This should probably be made part of the above described
    #        spine_local_internals_uris key
    # Parse the top level config directory if it exists.
    $self->read_config_branch( uri => "file:///" . $self->{c_croot} );

    # HOOKME  Discovery: policy selection
    #
    # Using the data we have gathered, construct the paths for
    # our hierarchy.
    #

    # Run our policy selection hooks
    $point = $registry->get_hook_point('DISCOVERY/policy-selection');

    $rc = $point->run_hooks($self);

    unless ( $rc == 0 ) {
        $DATA_POPULATED = SPINE_FAILURE;
        $self->error( 'DISCOVERY/policy-selection: Failed to run at least one'
                        . 'hook!',
                      'crit' );
        return SPINE_FAILURE;
    }

    $DATA_POPULATED = SPINE_SUCCESS;

    return SPINE_SUCCESS;
}

# This will kick off the actaul parsing of keys that are not related to boot
# strapping. It uses the Spine::Plugins::Data::* plugins to support keys
# from any source you can think of. Key parsing it's self is part of the
# Spine::Plugins::Parselet::* code
sub parse {
    my $self     = shift;
    my $registry = new Spine::Registry();
    my $errors   = 0;

    if ( $DATA_PARSED != SPINE_NOTRUN ) {
        return $DATA_PARSED;
    }

    # Make sure our discovery phases has been run first since we need a bunch
    # of that info for out parsing.  Most notably the descend order.
    unless ( $self->populate() == SPINE_SUCCESS ) {
        $self->error( 'PARSE: failed to run populate()!', 'crit' );
        goto parse_failure;
    }

    #
    # Begin parse
    #

    # HOOKME  Parse: parse initialize
    my $point = $registry->get_hook_point('PARSE/initialize');

    my $rc = $point->run_hooks($self);

    if ( $rc != 0 ) {
        $self->error( 'PARSE/initialize: Failed to run at least one hook!',
                      'crit' );
        goto parse_failure;
    }

    # Gather config data from the entire hierarchy.
    $self->cprint( 'descending hierarchy', 3 );
    foreach my $branch ( @{$self->getvals(SPINE_HIERARCHY_KEY, 1)} ) {        
        if ( $self->read_config_branch($branch) != 0 ) {
            goto parse_failure;
        }
    }

    # HOOKME  Parse: parse complete
    $point = $registry->get_hook_point('PARSE/complete');

    $rc = $point->run_hooks($self);

    if ( $rc != 0 ) {
        $self->error( 'PARSE/complete: Failed to run at least one hook!',
                      'crit' );
        goto parse_failure;
    }

    $self->print( 1, "parse complete" );

    return SPINE_SUCCESS;

  parse_failure:
    $DATA_PARSED = SPINE_FAILURE;
    return SPINE_FAILURE;
}

# public interface to allow a branch to be read. That means all the keys
# within that branch will be within Spine::Data once done.
# See Spine::Plugins::Data::* for implementaions
sub read_config_branch {
    my $self = shift;
    
    my $branch = Spine::Resource::resolve_resource(@_);
    
    unless (defined $branch) {
        $self->error("Issue resolving resource used to define a branch", 'err');
        return PLUGIN_ERROR;
    }

    my $registry = new Spine::Registry();

    # HOOKME  Parse: branch descent
    my $point = $registry->get_hook_point('PARSE/branch');

    $self->cprint( "processing branch (" . $branch->{uri} . ")", 3 );

    return $point->run_hooks( $self, $branch );

}

# a wrapper for read_key that does a little more checking and does not support
# current data unless it's key'ed into Spine::Data and a keyname => "foo" is
# given.
# simple usage read_keyuri(uri => "some://uri")
#   supports all standard Spine::Key metadata (see parselets)
sub read_keyuri {
    my $self = shift;

    my ( $item, $keyname );

    if ( scalar(@_) > 1 ) {
        $item = {@_};
    } else {
        $item = shift;
    }

    unless ( ref($item) eq "HASH" && exists $item->{uri} ) {
        $self->error( "call to read_keyuri without a uri option", "err" );
        return undef;
    }

    if ( exists $item->{keyname} ) {
        $keyname = $item->{keyname} if exists $item->{keyname};
        $item->{description} = "$keyname key"
          unless exists $item->{description};
    }

    # read the key with out item asking kindly to get
    # an object back
    my $values = $self->read_key($item);

    # if the current key was a Spine::Key then the return value
    # will be the same.
    if (defined $values && blessed $values && $values->isa("Spine::Key")) {
        $values = $values->get();
    }
    unless ( defined($values) ) {
        return wantarray ? () : undef;
    }

    # TODO: This is really backwards compatability
    #       and should be removed
    if ( ref($values) eq "ARRAY" ) {
        return wantarray ? @{$values} : $values;
    }

    return $values;
}

# read a new_key (can be a hash or a Spine::Key object)
# with optinal current key / data
# if return_obj is 1 then it will always return a Spine::Key
# if keyname is set within new_key then it will also store it
# within the Spine::Data tree
sub read_key {
    my ( $self, $new_key, $current, $return_obj) = @_;

    # unless the key is already an obj we will return raw data
    # that is unless the caller has said it really want the obj
    # XXX: one day perhaps all keys will be objects?? Probably not that bad?
    #      considering that the get hidden behind a tie when in Spine::Data;
    $return_obj = 0 unless defined $return_obj;

    # must have something to work on
    if (not defined $new_key) {
        $self->error("call to Spine::Data::read_key without data", "warn");
        return undef;
    } elsif (ref ($new_key) eq "HASH") {
        # if the new_key is just a hash then we assume that
        # we need to create a standard Spine::Key using the hash
        # content as the metadata
        my $meta_data = $new_key;
        $new_key = new Spine::Key;
        $new_key->metadata_set(%{$meta_data});
    } elsif (not blessed($new_key) || not $new_key->isa("Spine::Key")) {
        # something was passed but not anything we want....
        $self->error("bad argument given to Spine::Data::read_key", "warn");
        return undef;    
    } else {
        # we were given a Spine::Key so we will return one!
        $return_obj = 1;
    }
    
    # this could result in undef
    my $keyname = $new_key->metadata("keyname");
    
    # if we have no current object but have a keyname that might
    # result in one then try to get it
    unless (defined $current) {
        $current = $self->getkey($keyname) if (defined $keyname);
    }
    
    # if current is defined we work out if it's raw data or an object
    # if it's data then we put it within a Spine::Key object
    if (defined $current) {
        if (blessed($current) && $current->isa("Spine::Key")) {
            # since the passed in current key was a Spine::Key we will
            # return a Spine::Key
            $return_obj = 1;
        } else {
            $current = new Spine::Key($current);
        }
    }
    
    # at this point we have a least one src Spine::Key and posiably
    # a destination/current Spine::Key. We pass this to the hook point
    # return_item will be undef if there was an error or a Spine::Key
    my $return_item = $self->_call_key_hook($new_key, $current);
    
    # XXX: should we log an error here?
    return undef unless defined $return_item;
    
    # a final special case. If the return_item is not the same as the item
    # that was put then we always turn on return_obj. This is done becuase
    # one of the key parses has decided that the result should be a special
    # key object.
    if (ref($new_key) ne ref($return_item)) {
        $return_obj = 1;
    }
    
    # Will we return an object or it's data? If the caller passed in objects
    # then we assume they expect to get some back!
    $return_item = $return_obj ? $return_item : $return_item->get();
    
    # if the caller passed in the keyname then we save the key under that name
    if (defined $keyname) {
        $self->set($keyname, $return_item);
    }
    
 
    
    return $return_item;
}

# the raw read_key call all items passed in must be Spine::Key objects
# always returns a Spine::Key or undef if there was an issue
# XXX: I don't think this needs to be publically avaliable, but we are open to
#      sugestions as to why it might be help full
sub _call_key_hook {
    my ($self, $new_key, $current) = @_;

    # parse the key
    # HOOKME Parselet expansion
    my $registry = new Spine::Registry;
    my $point    = $registry->get_hook_point('PARSE/key');

    my $sref = undef;
    my $ret_key = \$sref;

    my ( undef, $rc, undef ) =
      $point->run_hooks_until( PLUGIN_STOP, $self, $new_key,
                               $current, $ret_key);

    if ( ($rc & PLUGIN_FATAL) == PLUGIN_FATAL) {
        return undef;
    }
        
    return $$ret_key;
}

sub getval {
    my $self = shift;
    my $key  = shift;

    $self->print( 4, "getval -> $key" );
    return undef unless ( exists $self->{$key} );

    if ( ( ref $self->{$key} ) eq "ARRAY" ) {
        return $self->{$key}[0];
    } else {
        return $self->{$key};
    }
}

# like getval but will always return the key
# never the first element
sub getkey {
    my $self = shift;
    my $key  = shift;
    $self->print( 4, "getkey -> $key" );
    return undef unless ( exists $self->{$key} );
    return $self->{$key};
}

# This simplifys most of spine but hiding special keys from 90% of the code
# anything that really really wants the key should call getkey to be 100%
# that it gets what it expects
sub hidekey {
    my ( $self, $keyname, $obj ) = @_;
    unless (exists $self->{$keyname} ) {
        $self->{$keyname} = "";
    }
    tie $self->{$keyname}, "Spine::Data::HiddenKey", $obj;
}

sub getval_last {
    my $self = shift;
    my $key  = shift;

    $self->print( 4, "getval -> $key" );
    return undef unless ( exists $self->{$key} );

    if ( ( ref $self->{$key} ) eq "ARRAY" ) {
        return $self->{$key}[-1];
    } else {
        return $self->{$key};
    }
}

sub getvals {
    my $self  = shift;
    my $key   = shift;
    my $force = shift || 0;

    $self->print( 4, "getvals -> $key" );

    unless ( $key && exists $self->{$key} ) {
        if ($force) {
            return [];
        } else {
            return undef;
        }
    }

    if ( ( ref $self->{$key} ) eq "ARRAY" ) {
        return $self->{$key};
    } else {
        return [$self->{$key}];
    }
}

sub getvals_as_hash {
    my $self = shift;
    my $key  = shift;

    $self->print( 4, "getval_as_hash -> $key" );

    return undef unless ( $key && exists( $self->{$key} ) );

    if ( ref($self->{$key}) eq 'ARRAY' ) {

        # Make sure it's an array with an even number of elements(greater than
        # zero)
        my $oe = scalar( @{$self->{$key}} );

        if ( $oe and not( $oe % 2 ) ) {
            my %vals_as_hash = @{$self->{$key}};
            return \%vals_as_hash;
        }
    } elsif ( ref($self->{$key}) eq 'HASH' ) {
        return $self->{$key};
    }

    return undef;
}

sub getvals_by_keyname {
    my $self          = shift;
    my $key_re        = shift || undef;
    my @matching_vals = ();

    $self->print( 4, "getvals_by_keyname -> $key_re" );

    foreach my $key ( keys( %{$self} ) ) {
        if ( $key =~ m/$key_re/ ) {
            push @matching_vals, ${ $self->{$key} };
        }
    }

    # Sorted for minimal changes in diffs of templates
    @matching_vals = sort @matching_vals;
    return ( scalar @matching_vals > 0 ) ? \@matching_vals : undef;
}

sub search {
    my $self  = shift;
    my $regex = shift;

    my @keys = grep( /$regex/, keys %{$self} );
    return \@keys;
}

sub set_label {
    my $self  = shift;
    my $label = shift;

    if ($label) {
        $self->{c_label} = $label;
        return 1;
    }

    return 0;
}

#
# This method checks its call stack to make sure that it isn't being called
# from anywhere inside Template::Toolkit and prevents any template from
# changing any "c_*" keys.
#
# FIXME  This should really happen for all the variables.  We should probably
#        have a Spine::Data::TemplateProxy class or similar that prevents a
#        template from modifying any data in it via TIE.  Shouldn't be too
#        difficult, come to think of it.
# FIXME  this needs a real rethink....
#
sub set {
    my $self        = shift;
    my $key         = shift;
    my $in_template = 0;

    # We should never get a stack deeper than 30
    foreach my $i ( 1 .. 30 ) {
        my @frame = caller($i);

        last unless scalar @frame;

        if ( $frame[3] =~ m/^Template/ ) {
            $in_template = 1;
            last;
        }
    }

    ####### TODO refactor this out
    # FIXME   This is pretty lame way to differentiate which context the
    #         template is running in. (Perhaps use Hash::Util::lock_hash())
    #
    # This is ok as long as we're in a key template instance but it's not ok
    # if we're in an overlay template instance.  Ain't life grand?
    if ( $in_template and not defined($Spine::Plugin::Templates::KEYTT) ) {
        $self->error( "We've got an overlay template that's trying to call "
                        . "Spine::Data::set($key).  This is bad.",
                      'err ' );
        die(Template::Exception->new( 'Spine::Data::set()',
                                      'Overlay template trying to call '
                                        . "Spine::Data::set($key).  Bad template"
                                    ) );
    }

    #
    # If it's a reference of any kind, don't make it an array.  This permits
    # plugins to call $c->set('c_my_plugin', $my_plugin_obj).  ONLY do this if
    # there's only one argument passed in.  Otherwise, push them in as an array
    if ( ref( $_[0] ) and scalar(@_) == 1 ) {
        # if it's a special Spine::Key then we tie it in to hide it's
        # implementation from most of the code you can get the real key
        # by calling Spine::Data::getkey (i prommise)
        if ( blessed $_[0] && $_[0]->isa("Spine::Key") ) {
            $self->hidekey( $key, $_[0] );
        } else {
            $self->{$key} = $_[0];
        }
    } elsif (scalar(@_) > 1) {
        $self->{$key} = [@_];
    } else {
        $self->{$key} = $_[0];
    }
    ########
    #XXX: removed, don't think this is needed as parselets do this!
    #     the idea that set will do some kind of merge it not a safe one
    #     and not expandable!
    #elsif ( exists( $self->{$key} ) && ref($self->{$key}) eq "ARRAY" ) {
    #    push @{ $self->{$key} }, @_;
    #} else {
    #    $self->{$key} = [@_];
    #}
    ########

    # TT gets awfully confused by return values
    $in_template ? return: return 1;
}

# TODO: remove, this should be part of Spine::Util.
#sub check_exec {
#    my $self = shift;
#    foreach my $binary (@_) {
#        return 0 unless ( defined $binary );
#        $self->print( 4, "checking binary $binary" );
#        if ( !-x "$binary" ) {
#            $self->error( "binary $binary is unavailable: $!", "crit" );
#            return 0;
#    }
#    return 1;
#        }
#}

# TODO: make plugabble, and probably move to a singleton logging module
#       so that you don't have to pass Spine::Data about all the time
sub cprint {
    my $self = shift;
    my ( $msg, $level ) = @_;
    my $log_to_syslog = shift || 1;

    if ( $level <= $self->{c_verbosity} ) {
        print $self->{c_label}, ": $msg\n"
          unless $self->{c_quiet};

        syslog( "info", "$msg" )
          if ( not $self->{c_dryrun} or $log_to_syslog );
    }
}

sub print {
    my $self = shift;
    my $lvl  = shift || 0;

    if ( $lvl <= $self->{c_verbosity} ) {

        #	print $self->{c_label}, '[', join('::', caller()), ']: ', @_, "\n";
        print $self->{c_label}, ': ', @_, "\n"
          unless $self->{c_quiet};
    }
}

sub log {
    my $self = shift;
    my $msg  = shift;

    if ( not $self->{c_dryrun} ) {
        syslog( 'info', "$msg" );
    }
}

sub error {
    my $self = shift;
    my ( $msg, $level ) = @_;
    $level = 'err'
      unless (
        $level =~ m/
			       alert|crit|debug|emerg|err|error|
			       info|notice|panic|warning|warn
			       /xi );
    $msg =~ tr/\n/ -- /;

    # needed for syslog
    $msg = "warning" if ( $msg eq 'warn' );

    unless ( $self->{c_verbosity} == -1 ) {
        print STDERR $self->{c_label} . ": \[$level\] $msg\n";
    }

    syslog( "$level", "$msg" )
      unless $self->{c_dryrun};
    push( @{ $self->{c_errors} }, $msg );
}

# TODO: make pluggable rather then just calling raw utils
sub util {
    my $self = shift;
    my $util = shift;

    no strict 'refs';
    my $return = &{ "Spine::Util::" . $util }(@_);
    use strict 'refs';
    if ( not defined $return ) {
        my $pargs = join( " ", @_ );
        $self->error( "$util failed to execute with args: $pargs", 'crit' );
    }
    return $return;
}

sub get_release {
    return (shift)->{c_release};
}

sub debug {
    my $lvl = shift;

    if ( $DEBUG >= $lvl ) {
        print STDERR "DATA DEBUG($lvl): ", @_, "\n";
    }
}

sub get_plugin_version {
    my $self        = shift;
    my $plugin_name = shift;
    my $registry    = new Spine::Registry();

    return $registry->get_plugin_version($plugin_name);
}

1;

# this is used to hide Spine::Key object in the Spine::Data tree
# only a call from Spine::Data::getkey will result in the obj being
# returned
package Spine::Data::HiddenKey;

sub TIESCALAR {
    my $class       = shift;
    my $real        = shift;
    my $ref_to_real = \$real;
    return bless $ref_to_real, $class;
}

sub FETCH {
    my ( undef, undef, undef, $sub ) = caller(1);

    # allow getkey to
    return ${ +shift } if ( $sub eq "Spine::Data::getkey" );

    # otherwise return the nice version
    return ${ ${ +shift }->data_getref() };
}

sub STORE {
    ${ +shift }->set(shift);
}

1;
