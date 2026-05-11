module CustomExceptions::HelpCenter
  class CurationSkipped < StandardError; end
  class ArticleBuildFailed < StandardError; end
end
