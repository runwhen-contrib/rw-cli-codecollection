/**
 * Broken Cloud Function source -- deliberate syntax error.
 * The build fails during deployment, leaving the function in a
 * FAILED / non-ACTIVE state for the health checks to detect.
 */
exports.brokenHandler = (req, res) => {
  const msg = "this function never deploys"
  res.status(500).send(msg);
// deliberately unclosed brace/paren to break the build
