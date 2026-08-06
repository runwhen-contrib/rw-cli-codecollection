/**
 * Healthy HTTP Cloud Function (gen1) for test fixtures.
 * Deploys cleanly and stays in ACTIVE state.
 */
exports.helloWorld = (req, res) => {
  res.status(200).send("OK");
};
