# FalkorDB RPM: packages the prebuilt libfalkordb.so Redis module together with
# a systemd service that runs redis-server with the module loaded.
#
# The module is built beforehand (see build-native.sh / `cargo build --release`);
# this spec only installs it. Use packaging/rpm/build-rpm.sh to drive rpmbuild.

%global debug_package %{nil}
%global __strip /bin/true
# The module is a self-contained cdylib; don't repack/strip or scan it.
%global __brp_strip %{nil}
%global __brp_strip_comment_note %{nil}
%global __brp_strip_static_archive %{nil}

%{!?fdb_version: %global fdb_version 99.99.99}
%{!?fdb_so: %global fdb_so libfalkordb.so}
%global fdb_libexec %{_libexecdir}/falkordb

Name:           falkordb
Version:        %{fdb_version}
Release:        1%{?dist}
Summary:        FalkorDB graph database (Redis module) with systemd service
License:        SSPL-1.0
URL:            https://github.com/FalkorDB/FalkorDB
Source0:        %{fdb_so}
Source1:        falkordb.service
Source2:        falkordb.conf
Source3:        falkordb.sysusers
Source4:        redis-server

BuildRequires:  systemd-rpm-macros
%{?sysusers_requires_compat}
%{?systemd_requires}
# A private upstream redis-server is bundled: the module crashes on load under
# Valkey (Fedora's redis-server), so the distro server cannot be used.
ExclusiveArch:  x86_64 aarch64

%description
FalkorDB is a low-latency graph database built as a Redis module. This package
installs the module, a default configuration in /etc/falkordb/falkordb.conf and
the falkordb.service systemd unit that runs the bundled redis-server with the
module loaded as the unprivileged "falkordb" user.

%prep
# Nothing to unpack: sources are prebuilt files.

%build
# Nothing to build: libfalkordb.so is built outside rpmbuild.

%install
install -D -m 0755 %{SOURCE0} %{buildroot}%{_libdir}/falkordb/falkordb.so
install -D -m 0644 %{SOURCE1} %{buildroot}%{_unitdir}/falkordb.service
install -D -m 0640 %{SOURCE2} %{buildroot}%{_sysconfdir}/falkordb/falkordb.conf
install -D -m 0644 %{SOURCE3} %{buildroot}%{_sysusersdir}/falkordb.conf
install -D -m 0755 %{SOURCE4} %{buildroot}%{fdb_libexec}/redis-server
install -d -m 0750 %{buildroot}%{_sharedstatedir}/falkordb

%pre
%sysusers_create_compat %{SOURCE3}

%post
%systemd_post falkordb.service

%preun
%systemd_preun falkordb.service

%postun
%systemd_postun_with_restart falkordb.service

%files
%{_libdir}/falkordb/falkordb.so
%{fdb_libexec}/redis-server
%{_unitdir}/falkordb.service
%{_sysusersdir}/falkordb.conf
%dir %attr(0750,root,falkordb) %{_sysconfdir}/falkordb
%config(noreplace) %attr(0640,root,falkordb) %{_sysconfdir}/falkordb/falkordb.conf
%dir %attr(0750,falkordb,falkordb) %{_sharedstatedir}/falkordb

%changelog
* Mon Nov 16 2026 FalkorDB Packager <packager@falkordb.com> - %{version}-1
- Initial RPM packaging
