package openlog;

use Dancer ':syntax';
use Dancer::Plugin::Database;
use Dancer::Plugin::SimpleCRUD;
use Dancer::Plugin::Locale::Wolowitz;
use Data::Dumper;
use JSON::XS ();
use Date::Period::Human ();
use HTTP::Date ();
use XML::FeedPP;
use Digest::SHA;
use File::Slurp;
use Graph::Easy;
use URI;
use Net::Twitter::Lite;
use Time::HiRes;
use Template;

# use AnyEvent;
## eventually, the polling/updating of event-sources will run in the background, the
## AnyEvent stuff here is a tentative test if this can run alongside the http server daemon
# my $tick;
# my $w = AE::timer 1, 5, sub {
#	$tick++;
#	print "Hi!\n";
#	open(my $fh, ">polls.json") or error("Could not write polls file: $!");
#	print $fh $tick;
# };


get '/manage-events' => sub {
        my $graph = Graph::Easy->new();
	my $rootnode = $graph->add_node('openlog');

	my $listing = "<br><br><b>Sources:</b><br>";
	foreach my $s ( keys %{ setting('event-sources') } ){
		my $ss = setting("event-sources");

		my $favicon = 'http://'. URI->new($ss->{$s}->{uri})->host() .'/favicon.ico' if $ss->{$s}->{uri};
		$favicon = 'http://cdn.last.fm/flatness/favicon.2.ico' if $ss->{$s}->{type} eq 'Last.fm';
		$favicon = 'http://www.twitter.com/phoenix/favicon.ico' if $ss->{$s}->{type} eq 'Twitter';

		$listing .= "<img src=\"$favicon\" height=\"16\" width=\"16\"> Type: $ss->{$s}->{type}<br>Service: $ss->{$s}->{service}<br>URI: <a href=\"".($ss->{$s}->{uri} || '')."\">".($ss->{$s}->{uri} || '')."</a><br>Username: $ss->{$s}->{username}<br><br>";

		my $node = Graph::Easy::Node->new()->set_attributes({
			label => "$ss->{$s}->{service} (".($ss->{$s}->{username} || $ss->{$s}->{uri}).")",
			link => "/",
			linkbase => "/",
		});
		$graph->add_edge($node, $rootnode, $ss->{$s}->{type});
	}

	$listing .= "<b>Targets:</b><br>";
	foreach my $s ( keys %{ setting('event-targets') } ){
		my $et = setting("event-targets");

		my $favicon = 'http://'. URI->new($et->{$s}->{uri})->host() .'/favicon.ico' if $et->{$s}->{uri};
		$favicon = 'http://cdn.last.fm/flatness/favicon.2.ico' if $et->{$s}->{type} eq 'Last.fm';
		$favicon = 'http://www.twitter.com/phoenix/favicon.ico' if $et->{$s}->{type} eq 'Twitter';

		$listing .= "<img src=\"$favicon\" height=\"16\" width=\"16\"> Type: $et->{$s}->{type}<br>Service: $et->{$s}->{service}<br>URI: <a href=\"".($et->{$s}->{uri} || '')."\">".($et->{$s}->{uri} || '')."</a><br>Username: $et->{$s}->{username}<br><br>";

		my $node = Graph::Easy::Node->new()->set_attributes({
			label => "$et->{$s}->{service} (".($et->{$s}->{username} || $et->{$s}->{uri}).")",
			link => "/",
			linkbase => "/",
		});
		$graph->add_edge($rootnode, $node, $et->{$s}->{type});
	}

	template 'manage-events' => {
		title	=> loc('Manage event sources'),
		listing	=> $listing,
		graph	=> $graph->as_boxart_html(),
	};
};

get '/manage-events/greasemonkey/openlog.user.js' => sub {
	header('Content-Type' => 'text/javascript; charset=utf-8');
	template 'greasemonkey',
            {  },
            { layout => 0 };
};

get '/manage-events/poll_event-sources' => sub {
	my $hashes = JSON::XS::decode_json( File::Slurp::read_file('polls.json') ) if -e 'polls.json';

	my $out = "Back to <a href=\"/manage-events\">".loc('Manage event sources')."</a>";

	my %stats;
	my $s = setting('event-sources');
	foreach my $key ( keys %{ $s } ){
		if( $s->{$key}->{type} eq 'Atom' ){
			my $uri = $s->{$key}->{uri};

			my $feed;
			eval {
				$feed = XML::FeedPP->new( $uri );
			};
			if(!$feed){
				return "Could not reach $uri";
			}
			$out .= "<h2>Atom Feed: $s->{$key}->{service} ($s->{$key}->{username})</h2>\n";
			$out .= "Feed title: ". $feed->title() ."<br><ul>\n";
			my $cnt=0;
			foreach my $item ( $feed->get_item() ) {
				## check for new entries
				my $hash;
				if( $item->guid() ){
					$hash = $item->guid();
				}elsif( $item->link() ){
					$hash = $item->link(); 
				}else{
					$hash = Digest::SHA::sha1_base64( $item->pubDate . $item->title );
				}

				unless( $hashes->{"$s->{$key}->{type}:$s->{$key}->{service}:$s->{$key}->{username}"}->{ $hash } ){
					$out .= "<li>Title: ". $item->title ."<br>Desc:". $item->description ."<br>\@ ". $item->get_pubDate_epoch ."</li>\n";

					## log event
					_log({
						epoch	=> $item->get_pubDate_epoch,
						via	=> $s->{$key},	# uri, name, username, ...
						what	=> {
							title		=> $item->title,
							description	=> $item->description,
						},
						# these feeds are quite incomplete, we don't
						# know where or with whom the user has triggered
						# these events; future helpers might deduct where
						# or with whom the user was from other events at
						# the same time-frame
					});

					$hashes->{"$s->{$key}->{type}:$s->{$key}->{service}:$s->{$key}->{username}"}->{ $hash } = $item->get_pubDate_epoch;

					$cnt++;
					$stats{cntEvents}++;
				}
			}
			$out .= "</ul>$cnt new feed items.";
		}elsif( $s->{$key}->{type} eq 'Twitter' ){
			require LWP::UserAgent;
			require Date::Parse;
 			my $ua = LWP::UserAgent->new;
			$ua->timeout(10);
			$ua->agent('Openlog Twitter consumer');
			my $response = $ua->get("https://api.twitter.com/1/statuses/user_timeline.json?include_entities=true&include_rts=true&screen_name=". $s->{$key}->{username} ."&count=200");
			if(!$response->is_success){
				return "Could not reach twitter: $response->status_line";
			}
			my $twit = JSON::XS::decode_json( $response->decoded_content );
			$out .= "<h2>$s->{$key}->{service}</h2><ul>\n";
			# $out = "<pre>".Dumper($twit);
			my $cnt=0;

			foreach my $item ( @{ $twit } ) {
				## check for new entries
				my $hash = $item->{id};		# Twitter IDs should be unique across Twitter

				## convert to epoch
				my $epoch = Date::Parse::str2time($item->{created_at});

				unless( $hashes->{"$s->{$key}->{type}:$s->{$key}->{service}:$s->{$key}->{username}"}->{ $hash } ){
					$out .= "<li>Text: $item->{text}<br>\@ ". localtime($epoch) ."</li>\n";

					## log event
					_log({
						epoch	=> $epoch,
						via	=> $s->{$key},	# uri, name, username, ...
						what	=> {
							title		=> $item->{text},
						},
						where	=> {
							coordinates	=> $item->{coordinates},
							geo		=> $item->{geo},
						},
						# the twitter geo stuff needs work and testing!
					});

					$hashes->{"$s->{$key}->{type}:$s->{$key}->{service}:$s->{$key}->{username}"}->{ $hash } = $epoch;

					$cnt++;
					$stats{cntEvents}++;
				}
			}
			$out .= "</ul>$cnt new tweets (status updates).";
		}elsif( $s->{$key}->{type} eq 'Last.fm' ){
		# http://ws.audioscrobbler.com/2.0/?method=user.getrecenttracks&user=<user>&api_key=<api_key>
			require Net::LastFMAPI;

			$out .= "<h2>$s->{$key}->{service} ($s->{$key}->{username})</h2>\n";
			# $out = "<pre>".Dumper($twit);

			my $iter = Net::LastFMAPI::lastfm_iter("user.getrecenttracks", user => $s->{$key}->{username} );
			my $cnt=0;
			while( my $track = $iter->() ){
				my $epoch = $track->{date}->{uts};	# the epoch timestamp

				## check for new entries
				my $hash = $epoch;			# the epoch timestamp

				if($track->{nowplaying} || !$track->{date}->{uts}){	# both signs for a "now playing" status
					$out .= "<li><img src=\"http://cdn.last.fm/flatness/global/icon_eq.gif\"> You are currently listening to \"$track->{artist}->{'#text'} - $track->{name}\" (not logged yet)</li>\n";
					next;
				}

				if( $hashes->{"$s->{$key}->{type}:$s->{$key}->{service}:$s->{$key}->{username}"}->{ $hash } ){
					last;	# recenttracks are sorted newest to oldest, so it should
						# be safe to break as soon as we reach a known track
				}

				$out .= "<li>You listened to \"$track->{artist}->{'#text'} - $track->{name}\" \@ ". localtime($epoch) ."</li>\n";

				## log event
				_log({
					epoch	=> $epoch,
					via	=> $s->{$key},	# uri, name, username, ...
					what	=> {
						category	=> 'Audio',
						title		=> "$track->{artist}->{'#text'} - $track->{name}",
						track		=> $track,
					}
					# these feeds are quite incomplete, we don't
					# know where or with whom the user has triggered
					# these events; future helpers might deduct where
					# or with whom the user was from other events at
					# the same time-frame
				});

				$hashes->{"$s->{$key}->{type}:$s->{$key}->{service}:$s->{$key}->{username}"}->{ $hash } = $epoch;

				$cnt++;
				$stats{cntEvents}++;

				if( ($cnt % 50) == 0 ){ sleep 5; } # try to obey last.fm's rate limit

				# last if $cnt >= 50;
			}
			$out .= "</ul>$cnt new tracks logged.";
		}elsif( $s->{$key}->{type} eq 'MPlayerLog' ){
			$out .= "<h2>$s->{$key}->{service} ($s->{$key}->{uri})</h2>\n";

			my $file = $s->{$key}->{uri}; $file =~ s/^file:\/\///;;
			if(!-f $file){
				$out .= "MplayerLog file not found: $file";
				next;
			}

			open(my $fh, "<$file");
			binmode($fh);
			my $lines = read_file($fh, array_ref => 1);
			$out .= Dumper($lines);
			foreach my $line (@{$lines}){
				if($line =~ /ID_FILENAME=(.*)/){
					$out .= "File: $1<br>";
				}
			}

			my $cnt=0;
		#	while( my $track = $iter->() ){
		#		my $epoch = $track->{date}->{uts};	# the epoch timestamp

		#		## check for new entries
		#		my $hash = $epoch;			# the epoch timestamp

		#		if($track->{nowplaying} || !$track->{date}->{uts}){	# both signs for a "now playing" status
		#			$out .= "<li><img src=\"http://cdn.last.fm/flatness/global/icon_eq.gif\"> You are currently listening to \"$track->{artist}->{'#text'} - $track->{name}\" (not logged yet)</li>\n";
		#			next;
		#		}

		#		if( $hashes->{"$s->{$key}->{type}:$s->{$key}->{service}:$s->{$key}->{username}"}->{ $hash } ){
		#			last;	# recenttracks are sorted newest to oldest, so it should
		#				# be safe to break as soon as we reach a known track
		#		}

		#		$out .= "<li>You listened to \"$track->{artist}->{'#text'} - $track->{name}\" \@ ". localtime($epoch) ."</li>\n";

		#		## log event
		#		_log({
		#			epoch	=> $epoch,
		#			via	=> $s->{$key},	# uri, name, username, ...
		#			what	=> {
		#				category	=> 'Audio',
		#				title		=> "$track->{artist}->{'#text'} - $track->{name}",
		#				track		=> $track,
		#			}
		#			# these feeds are quite incomplete, we don't
		#			# know where or with whom the user has triggered
		#			# these events; future helpers might deduct where
		#			# or with whom the user was from other events at
		#			# the same time-frame
		#		});

		#		$hashes->{"$s->{$key}->{type}:$s->{$key}->{service}:$s->{$key}->{username}"}->{ $hash } = $epoch;

		#		$cnt++;
				$stats{cntEvents}++;

		#		if( ($cnt % 50) == 0 ){ sleep 5; } # try to obey last.fm's rate limit

		#		# last if $cnt >= 50;
		#	}
			$out .= "</ul>$cnt new tracks logged.";
		}

		$stats{cntPolls}++;
	} # end of foreach subscription

	File::Slurp::write_file( "polls.json", {binmode => ':utf8'}, JSON::XS->new->indent->encode($hashes) );

	## let's also log these technical events, as this here is triggered manually
	my $ok = _log({
		epoch	=> time(),
		via	=> {
			service => 'openlog',
		},
		category=> 'openlog-poll-sources',
		what	=> "Polled $stats{cntPolls} sources and added $stats{cntEvents} event.",
		what_advanced => {
			cntPolls => $stats{cntPolls},
			cntEvents=> $stats{cntEvents},
		},
		manual	=> 1,
	});

	return $out;
};

get '/' => sub {
	## get events
	my $events_ref = _events({ limit => 50 });

	my @events;
	foreach my $event ( @$events_ref ){
		if( ref $event->{what} eq 'HASH' ){
			# apply different templates based on what-type
			my $what = $event->{what};
			if( $what->{category} eq 'Audio' ){
				$event->{what_advanced} = '<span>'.loc('Listening to').'</span> ';
				$event->{what_advanced} .= '"'. $what->{track}->{artist}->{'#text'} .' - '. $what->{track}->{name} .'"';
			}elsif( $what->{category} eq 'Video' ){
				$event->{what_advanced} = loc('Watching').' ';
				$event->{what_advanced} .= '<span>'. loc($what->{'sub-category'}) .'</span> '. $what->{description};
			}elsif( $what->{category} eq 'Text' ){
				$event->{what_advanced} = loc('Reading') .' '. $what->{title};
			}else{
				$event->{what_advanced} = $what->{title};
			}
			if( $event->{via} ){
				$event->{what_advanced} .= ' <span>'. loc('logged via') .'</span> '. $event->{via}->{service};
				$event->{what_advanced} .= "<span class=\"hidden\">$what->{description}</span>" if $what->{description};
			}
		}else{
			$event->{what_advanced} = $event->{what};
		}

		$event->{human_time} = Date::Period::Human->new({lang=>'en'})->human_readable( HTTP::Date::time2iso($event->{epoch}) );
		$event->{verbose_time} = localtime($event->{epoch});

		push(@events, $event);
	}

	template 'index' => {
		title		=> loc('My events'),
		header		=> '<meta http-equiv="refresh" content="300">',
		events		=> \@events,
		events_cnt	=> scalar(@$events_ref),
	};
};

post '/rate' => sub {
	if( !param('id') ){
		warn '/rate: No id supplied';
		return redirect '/';
	}

	my $ok = _rate({
		id	=> param('id'),
		rating	=> param('rating'),
	});

	return 'Error' if !$ok;
	return redirect '/';
};

post '/delete' => sub {
	if( !param('id') ){
		warn '/delete: No id supplied';
		return redirect '/';
	}

	my $ok = _delete({
		id	=> param('id'),
	});

	return 'Error' if !$ok;
	return redirect '/';
};



get '/log' => sub {
	## get events
	my $events_ref = _events({ limit => 500 });

	my (%what_sug,%where_sug,%with_sug);
	my (@what_suggestions,@where_suggestions,@with_suggestions);
	foreach my $event ( @$events_ref ){
		$what_sug{ $event->{what} }++ if $event->{what};
		$where_sug{ $event->{where} }++ if $event->{where};
		$with_sug{ $event->{with} }++ if $event->{with};
	}

	for(reverse sort { $what_sug{$a} cmp $what_sug{$b} } keys %what_sug){
		push(@what_suggestions, $_);
	}
	for(reverse sort { $where_sug{$a} cmp $where_sug{$b} } keys %where_sug){
		push(@where_suggestions, $_);
	}
	for(reverse sort { $with_sug{$a} cmp $with_sug{$b} } keys %with_sug){
		push(@with_suggestions, $_);
	}

	template 'log.tt' => {
		title			=> loc('Log an event'),
		what_suggestions	=> \@what_suggestions,
		where_suggestions	=> \@where_suggestions,
		with_suggestions	=> \@with_suggestions,
		video			=> ( param('video') ? 1 : undef ),
		audio			=> ( param('audio') ? 1 : undef ),
	};
};

post '/log' => sub {
	my $epoch = time();

	## process form input
	my $what;
	if( param('what_suggestion') ){
		$what = param('what_suggestion');
	}elsif( param('what_category') ){
		$what = {
			category	=> param('what_category'),
			"sub-category"	=> param('what_sub-category'),
			description	=> param('what_description'),
		};
	}else{
		$what = param('what');
	}

	my $event = {
		# let's do a more complete cluedo thing:
		# who is implicit
		epoch	=> param('epoch') || $epoch,	# when
		where	=> param('where_suggestion') || param('where'),
		what	=> $what,
		with	=> param('with'),
		manual	=> param('manual'),
	};

	my $ok = _log($event);

	return 'Error' if !$ok;
	return redirect '/';
};


## JSON API
##
post '/api/events' => sub {
	my $req = JSON::XS::decode_json( request()->{body} );

	return JSON::XS::encode_json( _events( $req ) );
};

post '/api/log' => sub {
	my $req = JSON::XS::decode_json( request()->{body} );

	return JSON::XS::encode_json( _log( $req ) );
};

post '/api/rate' => sub {
	my $req = JSON::XS::decode_json( request()->{body} );

	return JSON::XS::encode_json( _rate( $req ) );
};

post '/api/delete' => sub {
	my $req = JSON::XS::decode_json( request()->{body} );

	return JSON::XS::encode_json( _delete( $req ) );
};

## INTERNAL METHODS
##
sub _events {
	## expects a hashref, returns hashref, undef on error
	my $req = shift;

	my $limit = 'LIMIT '.$req->{limit} if $req->{limit};

	## our current storage backend is a mixture of SQL and JSON Objects:
	## get events
	my $events = database->prepare("SELECT * FROM events ORDER BY `epoch` DESC $limit; ") or error database->errstr;
	$events->execute() or return undef; # $events->errstr;
	my @res;
	while( my $event_json = $events->fetchrow_hashref() ){
		my $event = JSON::XS::decode_json($event_json->{json});

		# heal that due to how we store things, that the id is not part of the event obj
		$event->{id} = $event_json->{id};

		push(@res, $event);
	}

	return \@res;
}

sub _log {
	## expects a hashref containing a complete event (has epoch, has basic attribs), or an arrayref of complete events
	## returns undef on error
	my $ref = shift;

	$ref = [ $ref ] if ref $ref eq 'HASH';

	my $cnt;
	foreach my $event (@$ref){
		my $epoch;
		if($event->{epoch}){
			$epoch = $event->{epoch}; # get from obj
		}else{
			$epoch = time();
			$event->{epoch} = $epoch; # complete obj
		}	

		## do sql
		my $sth = database->prepare("INSERT INTO events (epoch, json) VALUES (?, ?); ") or error database->errstr;
		$sth->execute(
			$event->{epoch},
			JSON::XS->new->indent->utf8->encode($event)
		) or return undef; # todo, as this makes it not atomic! # die $sth->errstr;

		## targets, like Twitter, may not support reporting events with past dates, they add the now-time on submit
		## thus we need to trigger them immediately, although we block the UI for that..
		_log_event_targets($event);

		$cnt++;
	}

	return { count => $cnt };
}

sub _delete {
	## expects a hashref containing  id => <id>, or an arrayref of such constructs
	## returns undef on error
	my $ref = shift;

	$ref = [ $ref ] if ref $ref eq 'HASH';

	my $cnt;
	foreach my $event (@$ref){
		## do sql
		my $sth = database->prepare("SELECT `id` FROM events WHERE `id` = ?; ");
		$sth->execute( $event->{id} ) or return undef; # todo, as this makes it not atomic! # die $sth->errstr;
		$sth->fetchrow_hashref(); # to get rows

		if( !$sth->rows ){
			warn "Event $event->{id} not found.";
			next;
		}

		my $del = database->prepare("DELETE FROM events WHERE `id` = ?; ") or error database->errstr; #  limit doesnt work, is our sqlite compiled without the LIMIT option?
		$del->execute( $event->{id} ) or return undef; # todo, as this makes it not atomic! # die $sth->errstr;

		$cnt++;
	}

	return { count => $cnt };
}


sub _log_event_targets {
	my $event = shift;

	my $s = setting('event-targets');
	foreach my $key ( keys %{ $s } ){
		if( $s->{$key}->{type} eq 'Twitter' ){
			# Twitter has no concept of adding past events, as such,
			# we ignore events that are from the past (older than 10 minutes)
			next if (time() - $event->{epoch}) > 60*10;

			eval { # all sorts of errors may occur whioch we mostly ignore for now
				require WWW::Mechanize;
				my $mech = WWW::Mechanize->new();
				$mech->agent('Mozilla compatible'); # override the Mechanize shorthand and set LWP::UA directly
				$mech->cookie_jar({});
				$mech->get('https://twitter.com/');

				$mech->form_with_fields('session[username_or_email]','session[password]');
				$mech->field( 'session[username_or_email]'	=> $s->{$key}->{username} );
				$mech->field( 'session[password]'		=> $s->{$key}->{password} );
				$mech->submit();

				$mech->form_with_fields('status');
				$mech->field( 'status' => $event->{what} );
				$mech->submit();
			};

		#	my $twitter = Net::Twitter::Lite->new({
		#		username => $s->{$key}->{username},
		#		password => $s->{$key}->{password}
		#	});

		#	my $tweet = $event->{what};
		#	my $tweet = substr($tweet, 0,139); # Twitter accepts 140 chars max

		#	my $ok = $twitter->update({ status => $tweet });

		#	unless( defined $ok ){
 		#		# $twitter->get_error->{error};
		#	}
		}
	}
};

sub _rate {
	## expects a hashref, returns hashref, undef on error
	my $req = shift;

	return undef if !$req->{id};		# "id missing!"
	return undef if !$req->{rating};	# "rating missing!"

	## everything non-numeric means remove rating
	$req->{rating} = undef if $req->{rating} !~ /\d/;

	## do sql
	my $events = database->prepare("SELECT * FROM `events` WHERE `id` = ?; ");
	$events->execute( $req->{id} ) or return undef; # die $events->errstr;
	my $event_json = $events->fetchrow_hashref();

	## add rating
	my $event = JSON::XS::decode_json($event_json->{json});
	$event->{rating} = $req->{rating};
	$event_json = JSON::XS->new->indent->utf8->encode($event);

	## do sql
	my $sth = database->prepare("UPDATE events SET `json` = ? WHERE `id` = ?; ") or error database->errstr;
	$sth->execute( $event_json, $req->{id} ) or return undef; # die $sth->errstr;

	return { count => 1 };
}


simple_crud(
	record_title	=> 'event',
	prefix		=> '/events',
	db_table	=> 'events',
	editable	=> 1,
	deletable	=> 1,
	sortable	=> 1,
	paginate	=> 100,
	input_types	=> {
		'json' => 'textarea',
	},
	template	=> 'events'
);

sub init_db {
	my $db = database();
 
	my $sql = "create table if not exists events (
		id integer primary key AUTOINCREMENT,
		epoch string null,
		json blob null
	);";
	$db->do($sql) or die $db->errstr;
}

init_db;
start;
