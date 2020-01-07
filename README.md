db-infoscreen - App/Infoscreen for Railway Departures in Germany
---

[db-infoscreen homepage](https://finalrewind.org/projects/db-fakedisplay/)

db-infoscreen (formerly db-fakedisplay) shows departures at german train
stations, serving both as infoscreen / webapp and station board look-alike.

Thanks to the undocumented IRIS backend, it usually has very detailed
information about delay reasons and service limitations.

There's a public [db-infoscreen service on
finalrewind.org](https://dbf.finalrewind.org/). You can also host your own
instance if you like, see the Setup notes below.


Dependencies
---

 * perl >= 5.10
 * Cache::File (part of the Cache module)
 * Geo::Distance
 * Mojolicious
 * Travel::Status::DE::DBWagenreihung >= 0.00
 * Travel::Status::DE::DeutscheBahn >= 2.03
 * Travel::Status::DE::IRIS >= 1.21

Setup
---

db-infoscreen respects the following environment variables:

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
pass requests for db-infoscreen to the appropriate port. See the
`examples` directory for imprint and privacy policy samples.

You can run the app using a Mojo::Server of your choice, e.g.  **perl
index.pl daemon -m production** (quick&dirty, does not respect all variables)
or **hypnotad** (recommended). A systemd unit example is provided in
`examples/db-infoscreen.service`.

All code in this repository may be used under the terms of the BSD-2-Clause
(db-infoscreen, see COPYING) and MIT (jquery, jqueryui, and marquee libraries;
see the respective files) licenses.  Attribution is appreciated.

System requirements
---

Resource requirements depend on usage. For a few requests per second, about
50MB (150k inodes) cache and one or two CPU cores should be sufficient.
db-infoscreen typically needs 50MB RAM per worker process, though calculating
with 100MB per worker is recommended to leave a safety margin.
