#*******************************************************************************
#  Copyright (c) 2026 Contributors to the Eclipse Foundation
#
#  All rights reserved. This program and the accompanying materials
#  are made available under the terms of the Eclipse Public License v2.0
#  and Eclipse Distribution License v1.0 which accompany this distribution.
#
#  The Eclipse Public License is available at
#     https://www.eclipse.org/legal/epl-2.0/
#  and the Eclipse Distribution License is available at
#    http://www.eclipse.org/org/documents/edl-v10.php.
#*******************************************************************************/

## Downloads and builds OpenSSL from source, then exposes it as the imported
## targets OpenSSL::SSL and OpenSSL::Crypto. Use it when the system OpenSSL
## cannot support QUIC: older than 3.2, or built with 'no-quic'.
##
## Enabled with -DPAHO_OPENSSL_SOURCE=fetch. OpenSSL is not a CMake project, so
## it is driven through ExternalProject rather than FetchContent, which only
## populates sources and cannot build a Configure/make project.
##
## Sets, for the caller:
##   OPENSSL_VERSION, OPENSSL_INCLUDE_DIR, OPENSSL_SSL_LIBRARY
##   PAHO_OPENSSL_FETCH_TARGET - add_dependencies() target for SSL consumers

include(ExternalProject)
include(ProcessorCount)

if(MSVC)
  message(FATAL_ERROR
    "PAHO_OPENSSL_SOURCE=fetch is not supported with Visual Studio generators: "
    "building OpenSSL needs perl, NASM and an MSVC command prompt. Install a "
    "QUIC-capable OpenSSL (for example with vcpkg) and build with "
    "PAHO_OPENSSL_SOURCE=system and OPENSSL_ROOT_DIR pointing at it.")
endif()

find_program(PAHO_OPENSSL_PERL NAMES perl)
if(NOT PAHO_OPENSSL_PERL)
  message(FATAL_ERROR "PAHO_OPENSSL_SOURCE=fetch requires perl on PATH to configure OpenSSL.")
endif()

find_program(PAHO_OPENSSL_MAKE NAMES gmake make)
if(NOT PAHO_OPENSSL_MAKE)
  message(FATAL_ERROR "PAHO_OPENSSL_SOURCE=fetch requires GNU make on PATH to build OpenSSL.")
endif()

if(NOT PAHO_OPENSSL_FETCH_HASH)
  message(FATAL_ERROR
    "PAHO_OPENSSL_FETCH_HASH must be set to the SHA256 of "
    "openssl-${PAHO_OPENSSL_FETCH_VERSION}.tar.gz. The published value is listed "
    "with the release assets at https://github.com/openssl/openssl/releases")
endif()

if(PAHO_OPENSSL_FETCH_HASH STREQUAL "${PAHO_OPENSSL_FETCH_HASH_DEFAULT}"
   AND NOT PAHO_OPENSSL_FETCH_VERSION STREQUAL "${PAHO_OPENSSL_FETCH_VERSION_DEFAULT}")
  message(FATAL_ERROR
    "PAHO_OPENSSL_FETCH_VERSION is ${PAHO_OPENSSL_FETCH_VERSION} but "
    "PAHO_OPENSSL_FETCH_HASH is still the checksum of the default "
    "${PAHO_OPENSSL_FETCH_VERSION_DEFAULT} tarball. Set PAHO_OPENSSL_FETCH_HASH to "
    "the SHA256 of openssl-${PAHO_OPENSSL_FETCH_VERSION}.tar.gz.")
endif()

set(PAHO_OPENSSL_FETCH_DIR "${CMAKE_BINARY_DIR}/openssl-fetch")
set(PAHO_OPENSSL_INSTALL_DIR "${PAHO_OPENSSL_FETCH_DIR}/install")

## CMake 3.24 and later warn unless told what timestamp to give extracted files.
if(POLICY CMP0135)
  set(PAHO_OPENSSL_EXTRACT_TIMESTAMP DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
else()
  set(PAHO_OPENSSL_EXTRACT_TIMESTAMP "")
endif()

ProcessorCount(PAHO_OPENSSL_JOBS)
if(PAHO_OPENSSL_JOBS EQUAL 0)
  set(PAHO_OPENSSL_JOBS 1)
endif()

## Static and position independent, so the result can also be linked into the
## shared paho libraries. --libdir=lib keeps the imported paths below
## predictable: some platforms default to lib64. OpenSSL builds QUIC unless it
## is configured with no-quic, so there is nothing extra to enable for QUIC.
ExternalProject_Add(openssl_fetch
  URL "https://github.com/openssl/openssl/releases/download/openssl-${PAHO_OPENSSL_FETCH_VERSION}/openssl-${PAHO_OPENSSL_FETCH_VERSION}.tar.gz"
  URL_HASH "SHA256=${PAHO_OPENSSL_FETCH_HASH}"
  ${PAHO_OPENSSL_EXTRACT_TIMESTAMP}
  SOURCE_DIR "${PAHO_OPENSSL_FETCH_DIR}/src"
  BINARY_DIR "${PAHO_OPENSSL_FETCH_DIR}/src"
  CONFIGURE_COMMAND
    <SOURCE_DIR>/Configure
      "--prefix=${PAHO_OPENSSL_INSTALL_DIR}"
      "--openssldir=${PAHO_OPENSSL_INSTALL_DIR}/ssl"
      "--libdir=lib"
      no-shared no-tests no-docs -fPIC
  BUILD_COMMAND "${PAHO_OPENSSL_MAKE}" "-j${PAHO_OPENSSL_JOBS}"
  INSTALL_COMMAND "${PAHO_OPENSSL_MAKE}" install_sw
  BUILD_BYPRODUCTS
    "${PAHO_OPENSSL_INSTALL_DIR}/lib/libssl${CMAKE_STATIC_LIBRARY_SUFFIX}"
    "${PAHO_OPENSSL_INSTALL_DIR}/lib/libcrypto${CMAKE_STATIC_LIBRARY_SUFFIX}"
)

set(PAHO_OPENSSL_FETCH_TARGET openssl_fetch)

set(OPENSSL_VERSION "${PAHO_OPENSSL_FETCH_VERSION}")
set(OPENSSL_INCLUDE_DIR "${PAHO_OPENSSL_INSTALL_DIR}/include")
set(OPENSSL_SSL_LIBRARY "${PAHO_OPENSSL_INSTALL_DIR}/lib/libssl${CMAKE_STATIC_LIBRARY_SUFFIX}")
set(OPENSSL_CRYPTO_LIBRARY "${PAHO_OPENSSL_INSTALL_DIR}/lib/libcrypto${CMAKE_STATIC_LIBRARY_SUFFIX}")

## The headers only exist once openssl_fetch has run. Create the directory now
## so generators that track header dependencies do not fail at generate time.
file(MAKE_DIRECTORY "${OPENSSL_INCLUDE_DIR}")

set(THREADS_PREFER_PTHREAD_FLAG ON)
find_package(Threads REQUIRED)

add_library(OpenSSL::Crypto STATIC IMPORTED GLOBAL)
set_target_properties(OpenSSL::Crypto PROPERTIES
  IMPORTED_LOCATION "${OPENSSL_CRYPTO_LIBRARY}"
  INTERFACE_INCLUDE_DIRECTORIES "${OPENSSL_INCLUDE_DIR}"
)

add_library(OpenSSL::SSL STATIC IMPORTED GLOBAL)
set_target_properties(OpenSSL::SSL PROPERTIES
  IMPORTED_LOCATION "${OPENSSL_SSL_LIBRARY}"
  INTERFACE_INCLUDE_DIRECTORIES "${OPENSSL_INCLUDE_DIR}"
  ## A static OpenSSL needs the platform thread and dynamic loading libraries.
  INTERFACE_LINK_LIBRARIES "OpenSSL::Crypto;${CMAKE_DL_LIBS};Threads::Threads"
)

if(PAHO_BUILD_SHARED)
  message(WARNING
    "PAHO_OPENSSL_SOURCE=fetch links a statically built OpenSSL "
    "${PAHO_OPENSSL_FETCH_VERSION} into the shared paho libraries. The result is not "
    "patched by the system package manager, and a process that also loads the system "
    "OpenSSL ends up with two copies of it. Prefer a static paho build "
    "(PAHO_BUILD_STATIC=TRUE) or a QUIC-capable system OpenSSL.")
endif()

message(STATUS "Fetching and building OpenSSL ${PAHO_OPENSSL_FETCH_VERSION} into ${PAHO_OPENSSL_INSTALL_DIR}")
message(STATUS "OpenSSL built here uses ${PAHO_OPENSSL_INSTALL_DIR}/ssl as its default certificate directory, which has no CA bundle: set ssl_options.trustStore or SSL_CERT_FILE for server certificate verification.")
