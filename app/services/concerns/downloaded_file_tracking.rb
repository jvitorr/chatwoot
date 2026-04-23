module DownloadedFileTracking
  private

  def with_downloaded_files
    @downloaded_files = []
    yield
  ensure
    Array(@downloaded_files).each(&:close!)
  end

  def track_downloaded_file(downloaded_file)
    (@downloaded_files ||= []) << downloaded_file
  end
end
