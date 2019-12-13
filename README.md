# Maven release script
Maven release script to git.

# may need it
It uses xmllint commands, please install it (libxml2, iconv, xmlsec1, zlib)
http://www.xmlsoft.org/downloads.html


# Steps
- increase pom.xml version
- create release branch
- create release tag
- push to branch master
- increase pom.xml Snapshot version in branch develop