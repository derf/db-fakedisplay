db-infoscreen - App/Infoscreen for Railway Departures in Germany
---

[db-infoscreen homepage](https://finalrewind.org/projects/db-fakedisplay/)

db-infoscreen (formerly db-fakedisplay) shows departures at german train
stations, serving both as infoscreen / webapp and station board look-alike.

It aims to aggregate departure and train data from different sources and
combine them in a useful (and user-friendly) manner. It is intended both for a
quick glance at the departure board and for public transportation geeks looking
for details about specific trains.

There's a public [db-infoscreen service on
finalrewind.org](https://dbf.finalrewind.org/). You can also host your own
instance via carton/cpanminus or Docker if you like, see the Setup notes below.


Dependencies
---

 * perl >= 5.20
 * carton or cpanminus
 * build-essential
 * git

Installation
---

After installing the dependencies, clone the repository using git, e.g.

```
git clone https://git.finalrewind.org/db-fakedisplay
```

Make sure that all files (including `.git`, which is used to determine the
software version) are readable by your www user, and follow the steps in the
next sections.

Perl Dependencies
---

db-infoscreen depends on a set of Perl modules which are documented in
`cpanfile`. After installing the dependencies mentioned above, you can use
carton or cpanminus to install Perl dependencies locally.

In the project root directory (where `cpanfile` resides), run either

```
carton install
```

or

```
cpanm --installdeps .
```

and set `PERL5LIB=.../local/lib/perl5` before running index.pl or wrap it
with `carton exec hypnotoad index.pl`.

Note that you should provide imprint and privacy policy pages. Depending on
traffic volume, you may also want to increase the amount of worker processes
and install a caching proxy in front of DBF.  See the Setup notes below.

To update your DBF installation, run `git pull`, ensure that all files are
readable by your www user, and re-run `carton install` or `cpanm --installdeps
.`.

Installation with Docker
---

A db-infoscreen image is available on Docker Hub. You can install and run it
as follows:

```
docker pull derfnull/db-fakedisplay:latest
docker run --rm -p 8000:8092 -v "$(pwd)/templates:/app/ext-templates:ro" db-fakedisplay:latest
```

This will make the web service available on port 8000.  Note that you should
provide imprint and privacy policy pages, see the Setup notes below.

Use `docker run -e DBFAKEDISPLAY_WORKERS=4 ...` and similar to pass environment
variables to the db-infoscreen service.

To update your Docker installation, fetch a new image from Docker Hub and
re-start the container.

Setup
---

In hypnotoad mode (recommended), db-infoscreen respects the following environment variables:

| Variable | Default | Description |
| :------- | :------ | :---------- |
| DBFAKEDISPLAY\_LISTEN | `http://*:8092` | IP and Port for web service |
| DBFAKEDISPLAY\_STATS | _None_ | File in which the total count of backend API requests (excluding those answered from cache) is written |
| DBFAKEDISPLAY\_HAFAS\_API | `https://v5.db.transport.rest` | hafas-rest-api endpoint |
| DBFAKEDISPLAY\_IRIS\_CACHE | `/tmp/dbf-iris-mian` | Directory for IRIS schedule cache |
| DBFAKEDISPLAY\_IRISRT\_CACHE | `/tmp/dbf-iris-realtime` | Directory for IRIS realtime cache |
| DBFAKEDISPLAY\_WORKERS | 2 | Number of worker processes (i.e., maximum amount of concurrent requests) |

Set these as needed, create `templates/imprint.html.ep` (imprint) and
`templates/privacy.html.ep` (privacy policy), and configure your web server to
pass requests for db-infoscreen to the appropriate port. See the
`examples` directory for imprint and privacy policy samples.

You can then use a service supervisor of your choice to run **hypnotoad index.pl**
(using Mojolicious' hypnotoad server). See `examples/db-infoscreen.service`
for a systemd unit example.

For a quick&dirty setup on low-traffic sites you can also use **morbo index.pl**
or **perl index.pl daemon -m production**. In this case, DBFAKEDISPLAY\_LISTEN
and DBFAKEDISPLAY\_WORKERS have no effect. Morbo accepts IP and port
configuration using the `-l`/`--listen` switch (default: `http://*:3000`);
Daemon mode respects the MOJO\_LISTEN environment variable (default: `http://*:3000`).

For public-facing installations, you may want to enable caching in the reverse
proxy serving DBF. See `examples/nginx-cache.conf` and
`examples/nginx-site.conf` for nginx examples.

All code in this repository may be used under the terms of the BSD-2-Clause
(db-infoscreen, see COPYING) and MIT (jquery, jqueryui, and marquee libraries;
see the respective files) licenses.  Attribution is appreciated.

Background Data Updates
---

db-infoscreen can use <https://lib.finalrewind.org/dbdb/db_zugbildung_v0.json>
to show scheduled ICE/IC types (ICE 1/2/3/4/T, IC 1/2), wagon orders, and other
attributes. It expects the file to be provided in `share/zugbildungsplan.json`.

As this information is updated regularly, the file is not shipped as part of
this db-infoscreen distribution. It is recommended to retrieve it a few minutes
after midnight via a daily cronjob. See `examples/dbf_update_zugbildungsplan`
for a shell script.

DBF will periodically reload `share/zugbildungsplan.json`. You can use your
service supervisor (e.g. `systemctl reload db-infoscreen`) to force an
immediate reload. You may also ignore the file; it is entirely optional.

System requirements
---

Resource requirements depend on usage. For a few requests per second, about
200MB (600k inodes) cache and one or two CPU cores should be sufficient.
db-infoscreen typically needs 50MB RAM per worker process, though calculating
with 100MB per worker is recommended to leave a safety margin.

Licensing
---

This project follows the REUSE specification. The copyright of individual files
is documented in the file's header or in .reuse/dep5. The referenced licenses
are stored in the LICENSES directory.

The program code of db-infoscreen is licensed under the terms of the GNU AGPL
v3. HTML Templates and SASS/CSS layout are licensed under the terms of the
2-Clause BSD License. This means that you are free to host your own
db-infoscreen instance, both for personal/internal and public use, under the
following conditions.

* You are free to change HTML/SASS/CSS templates as you see fit (though you
  must not remove the copyright headers).
* If you make changes to the program code, that is, a file below lib/ or a
  db-infoscreen javascript file below public/static/js/, you must make those
  changes available to the public.

The easiest way of making changes available is by maintaining a public fork of
the Git repository. A tarball is also acceptable. Please change `source_url` in
`lib/DBInfoscreen.pm` to point to your Git repository / source archive if you
are using a version with custom changes.
