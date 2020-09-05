package DBInfoscreen::Controller::Wagenreihung;
use Mojo::Base 'Mojolicious::Controller';

# Copyright (C) 2011-2019 Daniel Friesel <derf+dbf@finalrewind.org>
# License: 2-Clause BSD

use Encode qw(decode);
use JSON;
use Mojo::Promise;
use Travel::Status::DE::DBWagenreihung;

my $dbf_version = qx{git describe --dirty} || 'experimental';

chomp $dbf_version;

sub get_wagenreihung_p {
	my ( $self, $train_no, $api_ts ) = @_;

	my $url
	  = "https://www.apps-bahn.de/wr/wagenreihung/1.0/${train_no}/${api_ts}";

	my $cache = $self->app->cache_iris_rt;

	my $promise = Mojo::Promise->new;

	if ( my $content = $cache->thaw($url) ) {
		$promise->resolve($content);
		$self->app->log->debug("GET $url (cached)");
		return $promise;
	}

	$self->ua->request_timeout(10)
	  ->get_p( $url, { 'User-Agent' => "dbf.finalrewind.org/${dbf_version}" } )
	  ->then(
		sub {
			my ($tx) = @_;
			$self->app->log->debug("GET $url (OK)");
			my $body = decode( 'utf-8', $tx->res->body );
			my $json = JSON->new->decode($body);

			$cache->freeze( $url, $json );
			$promise->resolve($json);
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->app->log->debug("GET $url (error: $err)");
			$promise->reject($err);
		}
	)->wait;
	return $promise;
}

sub wagenreihung {
	my ($self)    = @_;
	my $train     = $self->stash('train');
	my $departure = $self->stash('departure');

	$self->render_later;

	$self->get_wagenreihung_p( $train, $departure )->then(
		sub {
			my ($json) = @_;
			my $wr;
			eval {
				$wr
				  = Travel::Status::DE::DBWagenreihung->new(
					from_json => $json );
			};
			if ($@) {
				$self->render(
					'wagenreihung',
					title     => "Zug $train",
					wr_error  => scalar $@,
					train_no  => $train,
					wr        => undef,
					hide_opts => 1,
				);
			}

			if ( $wr->has_bad_wagons ) {

				# create fake positions as the correct ones are not available
				my $pos = 0;
				for my $wagon ( $wr->wagons ) {
					$wagon->{position}{start_percent} = $pos;
					$wagon->{position}{end_percent}   = $pos + 4;
					$pos += 4;
				}
			}

			$self->render(
				'wagenreihung',
				wr_error => undef,
				title    => join( ' / ',
					map { $wr->train_type . ' ' . $_ } $wr->train_numbers ),
				train_no  => $train,
				wr        => $wr,
				hide_opts => 1,
			);
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->render(
				'wagenreihung',
				title     => "Zug $train",
				wr_error  => scalar $err,
				train_no  => $train,
				wr        => undef,
				hide_opts => 1,
			);
		}
	)->wait;

}

1;
