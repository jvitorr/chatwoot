module Voice::CallErrors
  class NoCallPermission < StandardError; end
  class CallFailed < StandardError; end
  class NotRinging < StandardError; end
  class AlreadyAccepted < StandardError; end
end
