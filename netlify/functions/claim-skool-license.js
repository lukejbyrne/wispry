const { json } = require("./license");

exports.handler = async (event) => {
  return json(410, {
    error: "Direct Skool license claiming has moved.",
    detail: "Use the private member checkout link from the pinned Skool post.",
  });
};
