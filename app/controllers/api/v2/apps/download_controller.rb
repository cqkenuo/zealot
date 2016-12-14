class Api::V2::Apps::DownloadController < ActionController::API
  def show
    @app = App.friendly.find(params[:slug])
    @release = @app.releases.find_by(version: params[:version])

    if @app && @release && File.exist?(@release.file.path)
      headers['Content-Length'] = @release.filesize
      send_file @release.file.path,
                filename: @release.download_filename,
                disposition: 'attachment'
    else
      render json: { error: 'No found app file' }, status: :not_found
    end
  end
end