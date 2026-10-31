'use strict';

// Gas acceptance: the shared server-side acceptance (accept_job.js), under
// the name and request shape ({ orderId }) the released Driver App calls.
// Eligibility is the dispatch policy's, including the offer radius around
// the customer's location, and a driver already on a job is refused
// (`driver_on_job`).

const { acceptCallable } = require("./accept_job");

exports.acceptGasOrder = acceptCallable("gas", "orderId");
