
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

use strict;

package Spine::Plugin::Parselet::JSON;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);
use JSON::Syck;

# TODO: a whole lot more error checking and reporting of errors

our ($VERSION, $DESCRIPTION, $MODULE);
my $CPATH;

$VERSION = sprintf("%d", q$Revision$ =~ /(\d+)/);
$DESCRIPTION = "Parselet::JSON, processes JSON keys";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { 'PARSE/key/complex' => [ { name => "JSON", 
                                                  code => \&_parse_json_key,
                                                  provides => [ 'JSON' ],
                                                 } ],
                     },
          };

sub _parse_json_key {
    my ($c, $obj) = @_;

    my $data = $obj->get();
    
    # Skip refs, only scalars
    if (ref($data)) {
        return PLUGIN_SUCCESS;
    }

    if ( $data =~ m/^#?%JSON/ ) {
        $data = JSON::Syck::Load($data);
        if (defined ($data)) {
            $obj->set($data);
            return PLUGIN_SUCCESS;
        }
        return PLUGIN_ERROR;
    }
    return PLUGIN_SUCCESS;
}

1;