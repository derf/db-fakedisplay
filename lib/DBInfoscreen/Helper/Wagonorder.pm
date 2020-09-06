package DBInfoscreen::Helper::Wagonorder;

use strict;
use warnings;
use 5.020;

use DateTime;
use Encode qw(decode encode);
use Mojo::JSON qw(decode_json);
use XML::LibXML;

sub new {
	my ( $class, %opt ) = @_;

	my $version = $opt{version};

	$opt{header}
	  = { 'User-Agent' =>
		  "dbf/${version} +https://finalrewind.org/projects/db-fakedisplay" };

	return bless( \%opt, $class );

}

sub is_available {
	my ( $self, $train, $wr_link ) = @_;

	if ( $self->check_wagonorder( $train->train_no, $wr_link ) ) {
		return 1;
	}
	elsif ( $train->is_wing ) {
		my $wing = $train->wing_of;
		if ( $self->check_wagonorder( $wing->train_no, $wr_link ) ) {
			return 1;
		}
	}
	return;
}

sub check_wagonorder {
	my ( $self, $train_no, $wr_link ) = @_;

	my $url
	  = "https://lib.finalrewind.org/dbdb/has_wagonorder/${train_no}/${wr_link}";
	my $cache = $self->{cache};

	if ( my $content = $self->{cache}->get($url) ) {
		return $content eq 'y' ? 1 : undef;
	}

	my $ua = $self->{user_agent}->request_timeout(2);

	my $res = eval { $ua->head( $url => $self->{header} )->result };

	if ($@) {
		$self->{log}->debug("check_wagonorder($url): $@");
		return;
	}
	if ( $res->is_error ) {
		$cache->set( $url, 'n' );
		return;
	}
	else {
		$cache->set( $url, 'y' );
		return 1;
	}
}

1;
