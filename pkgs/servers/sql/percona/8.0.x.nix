{ lib, stdenv, fetchurl, bison, cmake, pkgconfig
, boost, icu, libedit, libevent, lz4, ncurses, openssl, protobuf, re2, readline, zlib
, numactl, perl, cctools, CoreServices, developer_cmds
, rapidjson, curl, libtirpc, cyrus_sasl
}:

let
self = stdenv.mkDerivation rec {
  version = "8.0.16-7";
  pname = "percona-server";

  src = fetchurl {
    url = "https://www.percona.com/downloads/Percona-Server-8.0/Percona-Server-${self.version}/source/tarball/percona-server-${version}.tar.gz";
    sha256 = "1677jm271l8jy7566r7lb5z1bfbfrc50yfkvggs58w4i4df6i3wg";
  };

  patches = [
    ../mysql/abi-check.patch
  ];

  nativeBuildInputs = [ bison cmake pkgconfig ];

  buildInputs = [
    boost icu libedit libevent lz4 ncurses openssl protobuf re2 readline zlib
    rapidjson curl libtirpc cyrus_sasl
  ] ++ lib.optionals stdenv.isLinux [
    numactl
  ] ++ lib.optionals stdenv.isDarwin [
    cctools CoreServices developer_cmds
  ];

  outputs = [ "out" "static" ];

  cmakeFlags = [
    "-DWITH_ROCKSDB=0" # Does not compile, cmake is configured wrong
    "-DCMAKE_OSX_DEPLOYMENT_TARGET=10.12" # For std::shared_timed_mutex.
    "-DCMAKE_SKIP_BUILD_RPATH=OFF" # To run libmysql/libmysql_api_test during build.
    "-DFORCE_UNSUPPORTED_COMPILER=1" # To configure on Darwin.
    "-DWITH_ROUTER=OFF" # It may be packaged separately.
    "-DWITH_SYSTEM_LIBS=ON"
    "-DWITH_UNIT_TESTS=OFF"
    "-DMYSQL_UNIX_ADDR=/run/mysqld/mysqld.sock"
    "-DMYSQL_DATADIR=/var/lib/mysql"
    "-DINSTALL_INFODIR=share/mysql/docs"
    "-DINSTALL_MANDIR=share/man"
    "-DINSTALL_PLUGINDIR=lib/mysql/plugin"
    "-DINSTALL_INCLUDEDIR=include/mysql"
    "-DINSTALL_DOCREADMEDIR=share/mysql"
    "-DINSTALL_SUPPORTFILESDIR=share/mysql"
    "-DINSTALL_MYSQLSHAREDIR=share/mysql"
    "-DINSTALL_MYSQLTESTDIR="
    "-DINSTALL_DOCDIR=share/mysql/docs"
    "-DINSTALL_SHAREDIR=share/mysql"
  ];

  postInstall = ''
    moveToOutput "lib/*.a" $static
    so=${stdenv.hostPlatform.extensions.sharedLibrary}
    ln -s libmysqlclient$so $out/lib/libmysqlclient_r$so
  '';

  passthru = {
    client = self;
    connector-c = self;
    server = self;
    mysqlVersion = "8.0";
  };

  meta = with lib; {
    homepage = "https://www.percona.com/";
    description = "a free, fully compatible, enhanced, open source drop-in replacement for MySQL that provides superior performance, scalability and instrumentation";
    license = licenses.gpl2;
    maintainers = with maintainers; [ m1cr0man ];
    platforms = platforms.unix;
  };
}; in self
