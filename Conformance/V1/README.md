# ELU SDK v1 config fixtures

This directory contains byte-exact public manifest, schema, and fixture
snapshots of the frozen cross-platform semantic contract from `ELU-Labs/elu-js` commit
`4df023251557bacc15c93b49d3f1ac2c6ca934da` (`contracts/v1`). They let this
package validate the config/privacy fixtures against their canonical schemas
without a sibling checkout or a network dependency. CI verifies every digest
below before schema evaluation.

Canonical SHA-256 values:

- contract manifest: `98152d8725c286f29402ba3e420bda8dd364200fb6fdf1cfe49b2da9b8f63e54`
- config schema: `4cd1e8fce0298048ec60ded16f9a215d10dc1022477f059e01db0349ec478307`
- privacy-policy schema: `73beb1856358f5e3cc45b225fdf0608294124e6d6f7c13e2ec3db1c285db6fc4`
- effective-privacy schema: `830726002dce98eafce30981067ea892afe12db2b985296514a8da3597776b14`
- enabled config fixture: `91be45589959f53c73a78f916f5e722b77a853fa0a6b952601400bf107b591e5`
- disabled config fixture: `c60d32c9701ea726cac342a8c06b89d9a6bd0cf6cea3441bcdd37c2de9055270`
- allowed privacy fixture: `a0fa41fbb06f263510b35c8d27863e8c69ecc52c940eac8fa23bdd4411c68f40`
- blocked privacy fixture: `503a2d118737bff7206f05c3cb83f4098579a5c92e7f49670b80e86df2e1e24d`

The transport remains `specified-not-wired`; these fixtures authorize no
public facade, network client, or production runtime by themselves.
