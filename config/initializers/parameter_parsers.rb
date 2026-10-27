# BulkPayments::RequestParser parses and validates JSON bodies itself. Rails parsing them first would answer a body
# with invalid encoding with its own HTML 400 before the controller runs, instead of the documented error object.
ActionDispatch::Request.parameter_parsers = ActionDispatch::Request.parameter_parsers.except(:json)
