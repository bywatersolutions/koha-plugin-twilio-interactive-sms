package Koha::Plugin::Com::ByWaterSolutions::TwilioSMS::API;

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use Modern::Perl;

use Mojo::Base 'Mojolicious::Controller';

use Data::Dumper;
use HTTP::Request::Common;
use LWP::UserAgent;
use Mojo::JSON qw(decode_json);

use C4::Circulation qw(CanBookBeRenewed AddRenewal _GetCircControlBranch);

=head1 API

=head2 Class Methods

=head3 Method to handle incoming SMS webhooks from Twilio

=cut

sub webhook {
    my $c = shift->openapi->valid_input or return;

    my $params = $c->req->params->to_hash;
    warn "PARAMS: " . Data::Dumper::Dumper( $c->req->params->to_hash );
    my $To       = $params->{From};   # Weird but less confusing in the long run
    my $incoming = $params->{Body};   # We are respnding *To* the *From* number

    my $token = $c->validation->param('token');

    my $plugin = Koha::Plugin::Com::ByWaterSolutions::TwilioSMS->new();

    my $WebhookAuthToken = $plugin->retrieve_data('WebhookAuthToken');
    my $AccountSid       = $plugin->retrieve_data('AccountSid');
    my $AuthToken        = $plugin->retrieve_data('AuthToken');
    my $From             = $plugin->retrieve_data('From');

    unless ( $token eq $WebhookAuthToken ) {
        return $c->render(
            status  => 401,
            openapi => { error => "Invalid token" }
        );
    }

    my $body = $params->{Body};
    my $from = $params->{From};

    warn qq{"$body" FROM $from};

    my $patron;

    # Look for exact match first
    unless ( $patron = Koha::Patrons->find( { smsalertnumber => $from } ) ) {

        # Look for a match without the country code
        $from =~ s/^\+1//g;    # Remove country code ( hard coded to USA atm )
        $patron = Koha::Patrons->find( { smsalertnumber => $from } );
    }

    # TODO: move this to a TWILIO_NO_CMD template
    my $outgoing =
      "I didn't understand your command. Send 'HELP' for a list of commands";

    my $code = "TWILIO_NO_CMD";
    my $lang = $patron ? $patron->lang : "default";

    my $tables = {};
    $tables->{borrowers} = $patron->id if $patron;

    my $objects = {};

    my $regexes = {
        TEST => '^TEST',
        HELP => '^HELP\s*ME',
        CHECKOUTS => '^MY\s*ITEMS',
        OVERDUES => '^OL',
        HOLDS_WAITING => '^HL',
        RENEW_ITEM => '^R (\S+)',
        RENEW_ALL_ODUE => '^RAO',
        RENEW_ALL => '^RA',
        ACCOUNTLINES => '^I\s*OWE',
        SWITCH_PHONE => '^SWITCH\s*PHONE (\S+)',
        LANGUAGES_LIST => '^LANGUAGES',
        LANGUAGES_SWITCH => '^LANGUAGE (\S+)',
    };

    if ( !$patron || $body =~ m/$regexes->{TEST}/i ) {
        $code = "TWILIO_TEST";
    }
    elsif ( $body =~ m/$regexes->{HELP}/i ) {
        $code = "TWILIO_HELP";
    }
    elsif ( $body =~ m/$regexes->{CHECKOUTS}/i ) {
        $code = "TWILIO_CHECKOUTS_CUR";
    }
    elsif ( $body =~ m/$regexes->{OVERDUES}/i ) {
        $code = "TWILIO_CHECKOUTS_OD";
    }
    elsif ( $body =~ m/$regexes->{HOLDS_WAITING}/i ) {
        $code = "TWILIO_HOLDS_WAITING";
    }
    elsif ( $body =~ m/$regexes->{RENEW_ITEM}/i ) {
        $code = "TWILIO_RENEW_ONE";
        my $barcode = $1;
        my $item = Koha::Items->find({ barcode => $barcode });
        $objects->{item} = $item;
        if ( $item ) {
            my ( $can, $reason ) = CanBookBeRenewed( $patron, $item->checkout );
            $objects->{can_renew} = $can;
            $objects->{cannot_renew_reason} = $reason;

            if ( $can ) {
                my $due_date = AddRenewal( $patron->id, $item->id, _GetCircControlBranch( $item->unblessed, $patron->unblessed ) );
                $objects->{renewal_due_date} = $due_date;
            }
        }
    }
    elsif ( $body =~ m/$regexes->{RENEW_ALL}/i || $body =~ m/$regexes->{RENEW_ALL_ODUE}/i ) { # Handle both "Renew All" and "Renew All Overdue"
        my $checkouts;

        if ( $body =~ m/$regexes->{RENEW_ALL_ODUE}/i ) {
            $code = "TWILIO_RENEW_ALL_OD";
            my $checkouts = $patron->overdues;
        } else {
            $code = "TWILIO_RENEW_ALL";
            $checkouts = $patron->checkouts;
        }

        my @results;
        if ( $checkouts ) {
            while ( my $c = $checkouts->next ) {
                my $data;
                my $item = $c->item;
                $data->{item} = $item;
                if ( $item ) {
                    my ( $can, $reason ) = CanBookBeRenewed( $patron, $item->checkout );
                    $data->{can_renew} = $can;
                    $data->{cannot_renew_reason} = $reason;

                    if ( $can ) {
                        my $due_date = AddRenewal( $patron->id, $item->id, _GetCircControlBranch( $item->unblessed, $patron->unblessed ) );
                        $data->{renewal_due_date} = $due_date;
                    }
                }
                push( @results, $data );
            }
        }

        $objects->{renewals} = \@results;
    }
    elsif ( $body =~ m/$regexes->{ACCOUNTLINES}/i ) {
        $code = "TWILIO_ACCOUNTLINES";
    }
    elsif ( $body =~ m/$regexes->{SWITCH_PHONE}/i ) {
        $code = "TWILIO_SWITCH_PHONE";
        my $phone_number = $1;

        if ( $phone_number =~ m/^(\+[1-9]\d{0,2})?\d{1,12}$/ ) {
            $patron->update({ smsalertnumber => $phone_number });
            $objects->{new_smsalertnumber} = $phone_number;
        }
    }
    elsif ( $body =~ m/$regexes->{LANGUAGES_LIST}/i ) {
        $code = "TWILIO_LANGUAGES";
        $objects->{languages} = C4::Languages::getTranslatedLanguages('opac');
    }
    elsif ( $body =~ m/$regexes->{LANGUAGES_SWITCH}/i ) {
        $code = "TWILIO_LANG_SWITCH";
        my $lang = $1;
        my $languages = C4::Languages::getTranslatedLanguages('opac');
        my $old_lang;
        my $new_lang;
        foreach my $l ( @$languages ) {
            $new_lang = $l 
                if lc $l->{language} eq lc $lang
                || lc $l->{rfc4646_subtag} eq lc $lang
                || lc $l->{native_description} eq lc $lang;
            $old_lang = $l if $l->{rfc4646_subtag} eq $patron->lang;
        }

        $objects->{requested_language};
        $objects->{new_language} = $new_lang;
        $objects->{old_language} = $old_lang;

        $patron->update({lang => $new_lang->{rfc4646_subtag} }) if $new_lang;
    }
    else {
        $code = "TWILIO_NO_CMD";
    }

    my $template =
      Koha::Notice::Templates->find( { code => $code, lang => $lang } ) || Koha::Notice::Templates->find( { code => $code, lang => 'default' } );
    my $template_content = $template->content;
    warn "TABLES: " . Data::Dumper::Dumper($tables);
    my $letter = C4::Letters::GetPreparedLetter(
        module      => 'circulation',
        letter_code => $code,
        lang        => $lang,
        tables      => $tables,
        objects     => {
            nothing => undef, # Placeholder in case $tables and $objects are empty
            %$objects,
        },
        message_transport_type => 'sms'
    );
    warn "LETTER: " . Data::Dumper::Dumper($letter);
    $outgoing = $letter->{content};

    warn "OUTGOING: $outgoing";

    my $ua = LWP::UserAgent->new;
    my $url =
      "https://api.twilio.com/2010-04-01/Accounts/$AccountSid/Messages.json";
    my $request = POST $url,
      [
        From => $From,
        To   => $To,
        Body => $outgoing,
      ];
    $request->authorization_basic( $AccountSid, $AuthToken );
    my $response = $ua->request($request);

    if ( $response->is_success ) {
        warn "RESPONSE: " . $response->decoded_content;
    }
    else {
        warn "Twilio response indicates failure: " . $response->status_line;
    }

    return $c->render(
        status  => 200,
        openapi => { bothered => Mojo::JSON->true }
    );
}

1;
