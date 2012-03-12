require "sinatra"
require "mogli"
require "oauth2"
require "dalli"

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
FACEBOOK_SCOPE = 'user_likes,user_photos,user_photo_video_tags'

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
    redirect "/auth/facebook" unless session[:at]

    @client = Mogli::Client.new(session[:at])
    puts "Created @client"
    
    @app  = Mogli::Application.find(ENV["FACEBOOK_APP_ID"], @client)
    @user = Mogli::User.find("me", @client)
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
  def url(path)
    base = "#{request.scheme}://#{request.env['HTTP_HOST']}"
    base + path
  end

  # STAGE 3: set additional fields in Facebook dialog calls
  def post_to_wall_url
    ["https://www.facebook.com/dialog/feed?",
      "redirect_uri=#{url("/close")}",
    "&display=popup",
    "&app_id=#{@app.id}",
    "&name=#{URI.escape("Heroku Cloudstock Charity Vote")}",
    "&picture=#{URI.escape(url('/images/logo-heroku.png'))}",
    "&caption=#{URI.escape("Vote for a charity donation")}",
    "&description=#{URI.escape("Your vote counts too. Vote for a charity donation by Heroku at Cloudstock.")}",
    "&link=#{url('/')}"].join
  end

  def send_to_friends_url(charity)
    ["https://www.facebook.com/dialog/feed?",
      "redirect_uri=#{url("/close")}",
    "&display=popup",
    "&app_id=#{@app.id}",
    "&name=#{URI.escape("Heroku FOWA Charity Vote")}",
    "&picture=#{URI.escape(url('/' + charity['Logo_URL__c']))}",
    "&caption=#{URI.escape("I voted for #{charity['Name']}!")}",
    "&description=#{URI.escape("Your vote counts too. Vote for a charity donation by Heroku at Cloudstock.")}",
    "&link=#{url('/')}"].join
  end

  def authenticator
    @authenticator ||= Mogli::Authenticator.new(ENV["FACEBOOK_APP_ID"], ENV["FACEBOOK_SECRET"], url("/auth/facebook/callback"))
  end
end

# the facebook session expired! reset ours and restart the process
error(Mogli::Client::HTTPException) do
  session[:at] = nil
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
  # limit queries to 15 results
  @client.default_params[:limit] = 15

  # STAGE 1: Get list of charities
  @charities = charities

  # STAGE 3: Manage voting
  @vote_counts = vote_counts

  @voted = Vote.first(:user_id => @user.id)

  @votes = Vote.all(:order => :created_at.desc, :limit => 11)
  @vote_total = Vote.count

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
      :user_id => @user.id,
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

get "/auth/facebook" do
  session[:at]=nil
  redirect authenticator.authorize_url(:scope => FACEBOOK_SCOPE, :display => 'page')
end

get '/auth/facebook/callback' do
  client = Mogli::Client.create_from_code_and_authenticator(params[:code], authenticator)
  session[:at] = client.access_token
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
  # Could just use @charities ||= dalli_client.get(CHARITIES_KEY), but we want
  # to explicitly show when we're using Memcache and when we're going to 
  # Force.com
  unless @charities
    @charities = dalli_client.get(CHARITIES_KEY)
    if @charities
      puts "***** Charities request served from Memcache"
    else
      puts "***** Querying Force.com for charities"
      query = "SELECT Id, Name, Logo_URL__c, URL__c from Charity__c ORDER BY Name"
      @charities = force_token.get("#{force_token.params['instance_url']}/services/data/v24.0/query/?q=#{CGI::escape(query)}").parsed['records']
      dalli_client.set(CHARITIES_KEY, @charities)
    end
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
