require "sinatra"
require 'koala'
require "oauth2"
require "dalli"
require 'memcachier'

$stdout.sync = true

enable :sessions
set :session_secret, ENV['SESSION_KEY'] || 'a super secret session key'
set :raise_errors, false
set :show_exceptions, false

# STAGE 3: Access Postgres via DataMapper
require 'data_mapper'

DataMapper.setup(:default, ENV['DATABASE_URL'] || 'postgres://localhost/my_database')

class Vote
  include DataMapper::Resource
  property :id,         Serial
  property :user_id,    String, :unique => true # Only one vote per user!
  property :charity_id, String
  timestamps :at
end

DataMapper.auto_upgrade!

# STAGE 2: Dalli is a Ruby client for memcache
def dalli_client
  @dalli_client ||= Dalli::Client.new(nil, :compression => true, :expires_in => 3600)
end

# Keys for memcache
CHARITIES_KEY    = 'charities'
ACCESS_TOKEN_KEY = 'access_token'
INSTANCE_URL_KEY = 'instance_url'

# Scope defines what permissions that we are asking the user to grant.
# In this example, we are asking for the ability to publish stories
# about using the app, access to what the user likes, and to be able
# to use their pictures.  You should rewrite this scope with whatever
# permissions your app needs.
# See https://developers.facebook.com/docs/reference/api/permissions/
# for a full list of permissions
FACEBOOK_SCOPE = 'user_likes,user_photos'

unless ENV["FACEBOOK_APP_ID"] && ENV["FACEBOOK_SECRET"]
  abort("missing env vars: please set FACEBOOK_APP_ID and FACEBOOK_SECRET with your app credentials")
end

# STAGE 1: Check for the env vars we need
unless ENV["CLIENT_ID"] && ENV["CLIENT_SECRET"] && ENV["USERNAME"] && ENV["PASSWORD"]
  abort("missing env vars: please set CLIENT_ID, CLIENT_SECRET, USERNAME and PASSWORD with your app credentials")
end

# STAGE 1: Get an OAuth access token from Force.com
def force_token
  # STAGE 2: Save access token and instance URL in Memcache
  access_token = dalli_client.get(ACCESS_TOKEN_KEY)
  instance_url = dalli_client.get(INSTANCE_URL_KEY)

  if access_token && instance_url
    @force_token  = OAuth2::AccessToken.from_hash(@force_client, 
      { :access_token => access_token, 
        :header_format => 'OAuth %s', 
        'instance_url' => instance_url } )
  else
    @force_token = @force_client.password.get_token(ENV['USERNAME'], ENV['PASSWORD'], {}, :header_format => 'OAuth %s')
    
    dalli_client.set(ACCESS_TOKEN_KEY, @force_token.token)
    dalli_client.set(INSTANCE_URL_KEY, @force_token.params['instance_url'])
  end
end

before do
  # HTTPS redirect
  if settings.environment == :production && request.scheme != 'https'
    redirect "https://#{request.env['HTTP_HOST']}"
  end
  # STAGE 3: Protect all non-auth, non-services URLs
  unless request.path =~ /^\/auth/ || request.path =~ /^\/charity/
    # Facebook session redirect
    redirect "/auth/facebook" unless session[:access_token]

    # Get base API Connection
    @graph  = Koala::Facebook::API.new(session[:access_token])
    
    # Get the user object    
    @user    = @graph.get_object("me")
    
    # Get public details of current application
    @app  =  @graph.get_object(ENV["FACEBOOK_APP_ID"])
  end
  
  # STAGE 1: Set up the Force.com OAuth2 client
  @force_client = OAuth2::Client.new(
      ENV['CLIENT_ID'],
      ENV['CLIENT_SECRET'], 
      :site => ENV['LOGIN_SERVER'] || 'https://login.salesforce.com', 
      :authorize_url =>'/services/oauth2/authorize', 
      :token_url => '/services/oauth2/token'
    )

  @force_token = force_token
end

helpers do
  def host
    request.env['HTTP_HOST']
  end

  def scheme
    request.scheme
  end

  def url_no_scheme(path = '')
    "//#{host}#{path}"
  end

  def url(path = '')
    "#{scheme}://#{host}#{path}"
  end

  def authenticator
    @authenticator ||= Koala::Facebook::OAuth.new(ENV["FACEBOOK_APP_ID"], ENV["FACEBOOK_SECRET"], url("/auth/facebook/callback"))
  end
  
  # allow for javascript authentication
  def access_token_from_cookie
    authenticator.get_user_info_from_cookies(request.cookies)['access_token']
  rescue => err
    warn err.message
  end

  def access_token
    session[:access_token] || access_token_from_cookie
  end

end

# the facebook session expired! reset ours and restart the process
error(Koala::Facebook::APIError) do
  session[:access_token] = nil
  redirect "/auth/facebook"
end

# STAGE 2: The Force.com session expired! reset ours and restart the process
error(OAuth2::Error) do
  if env['sinatra.error'].response.status == 401
    puts "***** Force.com token expired - resetting!"
    dalli_client.delete(ACCESS_TOKEN_KEY)
    dalli_client.delete(INSTANCE_URL_KEY)
    redirect "/"
  end
end

get "/" do
  if access_token
    @friends = @graph.get_connections('me', 'friends')
    @photos  = @graph.get_connections('me', 'photos')
    @likes   = @graph.get_connections('me', 'likes').first(4)

    # for other data you can always run fql
    @friends_using_app = @graph.fql_query("SELECT uid, name, is_app_user, pic_square FROM user WHERE uid in (SELECT uid2 FROM friend WHERE uid1 = me()) AND is_app_user = 1")

    # STAGE 1: Get list of charities
    @charities = charities

    # STAGE 3: Manage voting
    @vote_counts = vote_counts

    @voted = Vote.first(:user_id => @user['id'])

    @votes = Vote.all(:order => :created_at.desc, :limit => 11)
    @vote_total = Vote.count
  end

  erb :index
end

# used by Canvas apps - redirect the POST to be a regular GET
post "/" do
  redirect "/"
end

# STAGE 3: Receive a vote
post '/vote' do
  begin
    vote = Vote.create(
      :user_id => @user['id'],
      :charity_id => charity(params[:charity_id])['Id']
    )
    success = vote.save
  rescue DataObjects::IntegrityError => e
    success = false
  end

  content_type :json
  { :success => success , :vote_counts => vote_counts}.to_json
end

# used to close the browser window opened to post to wall/send to friends
get "/close" do
  "<body onload='window.close();'/>"
end

# Doesn't actually sign out permanently, but good for testing
get "/preview/logged_out" do
  session[:access_token] = nil
  request.cookies.keys.each { |key, value| response.set_cookie(key, '') }
  redirect '/'
end

# Allows for direct oauth authentication
get "/auth/facebook" do
  session[:access_token] = nil
  redirect authenticator.url_for_oauth_code(:permissions => FACEBOOK_SCOPE)
end

get '/auth/facebook/callback' do
	session[:access_token] = authenticator.get_access_token(params[:code])
	redirect '/'
end

# STAGE 2: Flush charity cache
delete '/charitycache' do
  puts "***** Flush charity cache"
  JSON.pretty_generate({ :success => dalli_client.delete(CHARITIES_KEY)}) + "\n"
end

# STAGE 3: Simple Web service to return vote data
get '/charityvotes' do
  puts "***** Get charity vote data"
  JSON.pretty_generate({ :success => true , :vote_counts => vote_counts}) + "\n"
end

# STAGE 1: Charity accessors
def charity(id)
  charities.find {|c| c['Id'] == id }
end

def charities
  # STAGE 2: Cache charities
  @charities ||= dalli_client.get(CHARITIES_KEY)
  if @charities
    puts "***** Charities request served from memcache"
  else
    puts "***** Querying Force.com for charities"
    query = "SELECT Id, Name, Logo_URL__c, URL__c from Charity__c ORDER BY Name"
    @charities = force_token.get("#{force_token.params['instance_url']}/services/data/v24.0/query/?q=#{CGI::escape(query)}").parsed['records']
    dalli_client.set(CHARITIES_KEY, @charities)
  end
  @charities
end

# STAGE 3: Get votes per charity
def vote_counts
  @vote_counts ||= charities.inject({}) do |result, charity|
    result[charity["Id"]] = Vote.all(:charity_id => charity["Id"]).count
    result
  end
end
