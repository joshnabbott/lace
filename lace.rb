# Lord Abbott's Cropping Extravaganza/Engine = L.A.C.E.
require 'rubygems'
require 'rack'
require 'open-uri'
require 'activesupport'
require 'aws'

class Lace
  BASE_DIR = '/Users/joshnabbott/Desktop/rack-images'

  def initialize
    @s3 = initialize_s3!('AKIAIVEUKBIYTRYPZZGQ','UMg0wkfc0X4fJ7OvFrJda+JMAwFwit4inLD9L8Qo')
  end

  def call(env)
    return if env['REQUEST_PATH'] =~ /favicon.ico/

    # Just ensure that this will even work before we get too deep into the image processing
    @params = self.extract_params(env)

    Lace.errors << 'Url is a required query string parameter' unless @params.has_key?(:url)

    Lace.errors << 'Invalid extension name' unless %w(png jpg jpeg).include?(self.file_extension)

    status, content_type, content = 500, { 'Content-Type' => 'text/plain' }, Lace.errors.join(' ') unless Lace.errors.empty?

    begin
      if Lace.errors.empty?
        status, content_type, content = 200, { 'Content-Type' => 'text/plain' }, generate!(env).to_s
      end
    ensure
      Lace.errors.clear
      GC.start
    end

    [status, content_type, content]
  end

  def self.errors
    @@errors ||= []
  end

protected
  def file_extension
    @file_extension ||= @params[:url].nil? ? '' : File.extname(@params[:url]).split('.').last
  end

  def extract_file_name(request_path)
    { :file_name => request_path.split('/').last }
  end

  def extract_params(env)
    returning Hash.new do |params|
      params.merge!(extract_query_params(env['QUERY_STRING']))
      params.merge!(extract_file_name(env['REQUEST_PATH']))
      params.merge!(extract_width_and_height(env['REQUEST_PATH']))
    end
  end

  def extract_query_params(query_string)
    return {} unless query_string

    query_string.split('&').inject({}) do |hash, pair|
      params = pair.split('=')
      hash[:"#{params.first}"] = params.last
      hash
    end
  end

  def extract_width_and_height(request_path)
    width_and_height = request_path.split('/').detect { |element| element =~ /x/ }
    elements         = width_and_height.split('x')
    width, height    = elements.first, elements.last
    { :width => width, :height => height }
  end

  def generate!(env)
    begin
      tempfile = Tempfile.new('LaceCrop')
      tempfile.binmode

      command = returning '' do |command|
        command << `which convert`
        command << " #{self.original}"
        command << ' -strip'
        if @params[:x1] && @params[:y1] && @params[:x2] && @params[:y2]
          command << " -crop '#{@params[:x2].to_i - @params[:x1].to_i}x#{@params[:y2].to_i - @params[:y1].to_i}+#{@params[:x1]}+#{@params[:y1]}!' +repage"
        end
        command << " -resize #{@params[:width]}x#{@params[:height]}"
        command << ' -unsharp 0x.25'

        # if params[:scale]
        #   command += " -bordercolor #{options[:background_color]}"
        #   command += " -border #{borders.join('x')}"
        # else
        #   command += " -gravity #{gravity}"
        #   command += " -crop '#{resize_to.first}x#{resize_to.last}+0+0!' +repage"
        # end

        command << " -quality 85"
        command << " -interlace Plane"
        command << " -format #{self.file_extension}"
        command << " #{self.file_extension}:#{tempfile.path}"
        command << " #{tempfile.path}"
        command << "&"
      end

      command = command.gsub("\n", '')
      # puts command.inspect
      result = `#{command}`
      # puts $?
    ensure
      tempfile.close
    end
    save_to_s3!(env, tempfile)
  end

  def save_to_s3!(env, file)
    shard_bucket = "oakley-s#{@params[:id].to_i % 4}"
    save_path    = env['REQUEST_PATH'][1..(env['REQUEST_PATH'].length - 1)]
    response     = @s3.put(shard_bucket, save_path, File.open(file.path), { 'x-amz-acl' => 'public-read' })
    response ? ['http://s3.amazonaws.com', shard_bucket, save_path].join('/') : response.inspect
  end

  # Return the path to an image that can be used for processing.
  # If the file exists locally, we just return the path to it.
  # If the file exists on a remote server (eg. at a url), we'll copy it down as a tmpfile and return the path to it.
  def original
    return @params[:url] if File.exist?(@params[:url])

    begin
      uri         = URI.parse(@params[:url])
      source_file = Tempfile.new('LaceOriginal')
      blob        = open(uri.to_s, 'rb') { |file| file.read }
      source_file.binmode
      source_file.write(blob)
    ensure
      source_file.close if source_file
    end
    source_file.path
  end

  def returning(value)
    yield(value)
    value
  end

private
  def initialize_s3!(access_key_id, secret_access_key)
    Aws::S3Interface.new(access_key_id, secret_access_key)
  end
end

Rack::Handler::Thin.run Lace.new, :Port => 3000