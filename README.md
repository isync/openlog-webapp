Openlog Web-App
===============

This here is is the web-application that serves as a reference
implementation of the Openlog [specifications](https://raw.github.com/opnlg/openlog-specs/master/openlog)
and demonstrates the Openlog personal life logging principles
in action.

The Openlog web-app is a Perl application written on-top of the
light Dancer application framework. To install/ test it do:

    wget https://github.com/opnlg/openlog-webapp/archive/master.zip
    unzip master.zip
    cd openlog-webapp-master

move the bundled example config file into place with:

    mv config.example.yml config.yml

install required modules:

    sudo cpan -i AnyEvent \
    Dancer \
    Dancer::Plugin::Database \
    Dancer::Plugin::Locale::Wolowitz \
    Dancer::Plugin::SimpleCRUD \
    Data::Dumper \
    DateTime \
    DateTime::Format::MySQL \
    Date::Parse \
    Date::Period::Human \
    Digest::SHA \
    File::Slurp \
    Graph::Easy \
    HTTP::Date \
    JSON::XS \
    LWP::UserAgent \
    Net::LastFMAPI \
    Net::Twitter::Lite \
    Template \
    Time::HiRes \
    URI \
    WWW::Mechanize \
    XML::FeedPP

After that, you can start your local, personal Openlog server with:

    perl bin/app.pl

An Openlog server is meant to be run locally, so after firing up the 
web-app your Openlog server should be accessible with your browser at:

[http://localhost:3000](http://localhost:3000)


## Help us develop Openlog

Openlog is a community effort. If you are able to contribute, do so.
The [TODO](https://raw.github.com/opnlg/openlog-webapp/master/TODO)
file contains some pointers where work is needed most. So, why don't 
you [fork](https://github.com/opnlg/openlog-webapp/fork) openlog-webapp
right now and start contributing!


## About Openlog

Openlog is a set of assumptions, standards, recommendations for
best practice and offers an example implementation of a protocol
and a web application which makes use of the above for a facility
that enables a user to keep track of personal events over a period
of time in a structured, machine-readable/-exchangeable manner.

The [Openlog specifications](https://raw.github.com/opnlg/openlog-specs/master/openlog),
sort of an inofficial RFC can be found [here](https://raw.github.com/opnlg/openlog-specs/master/openlog).


## Copyright / License

Copyright 2012-2013 Openlog Initiative

Openlog software, like this webapp here, is licensed under the GNU
GPL 3.0 license. You may obtain a copy of the License in the LICENSE
file, or at:

[http://www.gnu.org/licenses/gpl](http://www.gnu.org/licenses/gpl)

Documentation is licensed under the GNU Free Documentation License
Version 1.3. You may obtain a copy of the License at:

[http://www.gnu.org/licenses/fdl-1.3](http://www.gnu.org/licenses/fdl-1.3)
