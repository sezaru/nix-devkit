{
  fetchFromGitHub,
  lib,
  postgresql,
  postgresqlBuildExtension,
}:
postgresqlBuildExtension (finalAttrs: {
  pname = "pg_textsearch";
  version = "0.5.1";

  src = fetchFromGitHub {
    owner = "timescale";
    repo = "pg_textsearch";
    tag = "v${finalAttrs.version}";
    hash = "sha256-Lr7W4p/A2lYWg2McecIN4zPoDgMeM6/2k/0Di9Zc00Q=";
  };

  meta = {
    description = "BM25 relevance-ranked full-text search for PostgreSQL";
    homepage = "https://github.com/timescale/pg_textsearch";
    license = lib.licenses.postgresql;
    platforms = postgresql.meta.platforms;
    maintainers = [];
  };
})
