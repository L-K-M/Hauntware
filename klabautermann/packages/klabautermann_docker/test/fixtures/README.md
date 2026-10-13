# Hand-written fixtures

Every file in this directory was written by hand from the Docker Engine
API documentation and the version notes in `docs/design/klabautermann/03`
section 5.8. None of them were captured from a real daemon; spike S1's
capture tooling (`klabautermann/tool/capture_fixtures.dart`, 03 section
11.3) replaces them with recordings from real daemons in CI.

Version claims follow the plan, not live daemons: Docker 29.0 to 29.2
rejected clients below API 1.44, 29.3 lowered the floor to 1.40, and
Podman's compat layer reports max API 1.44, min 1.24.
