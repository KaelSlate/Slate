# Build-time belt for the AUTO-HEAL in CMakeLists.txt: the flutter tool's
# unpack step deletes/recopies ephemeral/cpp_client_wrapper on every build,
# and an IDE indexer (clangd) holding the .cc files makes that recopy come
# back include-only. Runs as PRE_BUILD on the wrapper targets — after the
# unpack, before MSVC — and restores stragglers straight from the engine
# cache. No-op when everything is in place.
if(NOT EXISTS "${DST}/core_implementations.cc")
  message(STATUS "[AUTO-HEAL] wrapper sources missing at build time - restoring from ${SRC}")
  file(GLOB _wrapper_files "${SRC}/*")
  file(COPY ${_wrapper_files} DESTINATION "${DST}")
endif()
