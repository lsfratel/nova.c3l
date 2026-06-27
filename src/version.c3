module nova;

import std::core::string;

<*
 Major version, incremented for incompatible API changes.
*>
const uint VERSION_MAJOR = 0;

<*
 Minor version, incremented for backward-compatible additions.
*>
const uint VERSION_MINOR = 5;

<*
 Patch version, incremented for backward-compatible fixes.
*>
const uint VERSION_PATCH = 0;

<*
 Semantic version string, kept in sync with the components.
*>
const String VERSION = string::@sprintf("%s.%s.%s", VERSION_MAJOR, VERSION_MINOR, VERSION_PATCH);
