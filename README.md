db-fakedisplay - Infoscreen for DB departures
---------------------------------------------

* <https://finalrewind.org/projects/db-fakedisplay/>

Dependencies
------------

 * perl >= 5.10
 * Cache::File (part of the Cache module)
 * Mojolicious
 * Mojolicious::Plugin::BrowserDetect
 * Travel::Status::DE::DeutscheBahn >= 2.03
 * Travel::Status::DE::IRIS >= 1.21

Setup
-----

db-fakedisplay respects the following environment variables:

| Variable | Default | Description |
| :------- | :------ | :---------- |
| DBFAKEDISPLAY\_LISTEN | `http://*:8092` | IP and Port for web service |
| DBFAKEDISPLAY\_STATS | _None_ | File in which the total count of backend API requests (excluding those answered from cache) is written |
| DBFAKEDISPLAY\_HAFAS\_CACHE | `/tmp/dbf-hafas` | Directory for HAFAS cache |
| DBFAKEDISPLAY\_IRIS\_CACHE | `/tmp/dbf-iris-mian` | Directory for IRIS schedule cache |
| DBFAKEDISPLAY\_IRISRT\_CACHE | `/tmp/dbf-iris-realtime` | Directory for IRIS realtime cache |
| DBFAKEDISPLAY\_WORKERS | 2 | Number of concurrent worker processes |

Set these as needed, create `templates/imprint.html.ep` (imprint) and
`templates/privacy.html.ep` (privacy policy), and configure your web server to
reverse proxy requests for db-fakedisplay to the appropriate port.

You can then run the app using a Mojo::Server of your choice, e.g.  **perl
index.pl daemon -m production** (quick&dirty, does not respect all variables)
or **hypnotad** (recommended).

All code in this repository may be used under the terms of the BSD-2-Clause
(db-fakedisplay, see COPYING) and MIT (jquery, jqueryui, and marquee libraries;
see the respective files) licenses.  Attribution is appreciated.

System requirements
-------------------

Resource requirements depend on usage. For a few requests per second, about
50MB (150k inodes) cache and one or two CPU cores should be sufficient.
db-fakedisplay typically needs 50MB RAM per worker process, though calculating
with 100MB per worker is recommended to have an appropriate safety margin.
