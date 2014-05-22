# Dart Quick Start Guide

This guide will walk you through deploying a Dart application on Deis.

## Usage

```
$ deis create
Creating application... done, created bubbly-gemstone
Git remote deis added
$ deis config:set DART_SDK_URL=https://github.com/selkhateeb/heroku-vagrant-dart-build/releases/download/latest/dart-sdk.tar
Creating config... done, v2

=== bubbly-gemstone
DART_SDK_URL: https://github.com/selkhateeb/heroku-vagrant-dart-build/releases/download/latest/dart-sdk.tar
$ git push deis master
Counting objects: 507, done.
Delta compression using up to 8 threads.
Compressing objects: 100% (444/444), done.
Writing objects: 100% (507/507), 9.31 MiB | 0 bytes/s, done.
Total 507 (delta 33), reused 497 (delta 33)
-----> Dart app detected
-----> ENV_DIR is
-----> Welcome, this machine is: Linux 0cb12d98c04a 3.14.4+ #2 SMP Wed May 14 02:38:49 UTC 2014 x86_64 x86_64 x86_64 GNU/Linux
-----> Installing Dart VM via URL https://github.com/selkhateeb/heroku-vagrant-dart-build/releases/download/latest/dart-sdk.tar
remote:   % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
remote:                                  Dload  Upload   Total   Spent    Left  Speed
remote: 100   339  100   339    0     0    733      0 --:--:-- --:--:-- --:--:--   991
remote: 100 11.5M  100 11.5M    0     0  2403k      0  0:00:04  0:00:04 --:--:-- 2896k
-----> Copy Dart binaries to app root
-----> Dart cmd found at -rwxr-xr-x 1 root root 11468640 May 22 23:28 /app/dart-sdk/bin/dart
remote: Dart VM version: 1.3.0 (Tue Apr 15 03:03:20 2014) on "linux_x64"
-----> Dart reports version:
       *** Found pubspec.yaml in /tmp/build/.
       *** Running pub get
       Pub 1.3.0
       Resolving dependencies... (3.1s)
       Downloading http_server 0.9.2...
       Downloading browser 0.10.0+2...
       Downloading path 1.1.0...
       Downloading mime 0.9.0+1...
       Got dependencies!
       *** Running pub build
       Building with "pub build"
       Loading source assets... (0.4s)
       Building basic_http_server... (0.1s)
       [Info from Dart2JS]:
       Compiling basic_http_server|web/index.dart...
       [Info from Dart2JS]:
       Took 0:00:05.600458 to compile basic_http_server|web/index.dart.
       Built 5 files to "build".
       total
-----> Discovering process types
       Procfile declares types -> web
-----> Compiled slug size is 12M
remote: -----> Building Docker image
remote: Uploading context 12.27 MB
remote: Uploading context
remote: Step 0 : FROM deis/slugrunner
remote:  ---> 5567a808891d
remote: Step 1 : RUN mkdir -p /app
remote:  ---> Using cache
remote:  ---> 4096b5c0b838
remote: Step 2 : ADD slug.tgz /app
remote:  ---> 9f910ee4f293
remote: Removing intermediate container d208143d9398
remote: Step 3 : ENTRYPOINT ["/runner/init"]
remote:  ---> Running in aabeb0aaed6f
remote:  ---> b1ab2203769b
remote: Removing intermediate container aabeb0aaed6f
remote: Successfully built b1ab2203769b
remote: -----> Pushing image to private registry
remote:
remote:        Launching... done, v3
remote:
remote: -----> bubbly-gemstone deployed to Deis
remote:        http://bubbly-gemstone.local.deisapp.com
remote:
remote:        To learn more, use `deis help` or visit http://deis.io
remote:
To ssh://git@local.deisapp.com:2222/bubbly-gemstone.git
 * [new branch]      master -> master
$ curl http://bubbly-gemstone.local.deisapp.com
```

## Additional Resources

* [Get Deis](http://deis.io/get-deis/)
* [GitHub Project](https://github.com/opdemand/deis)
* [Documentation](http://docs.deis.io/)
* [Blog](http://deis.io/blog/)
