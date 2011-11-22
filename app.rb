require 'rubygems'
require "sinatra"
require "mogli"
require 'erb'
require 'cgi'
require 'zip/zip'
require 'bunny'
require 'json'

enable :sessions
set :raise_errors, false
set :show_exceptions, false

# Scope defines what permissions that we are asking the user to grant.
# In this example, we are asking for the ability to publish stories
# about using the app, access to what the user likes, and to be able
# to use their pictures.  You should rewrite this scope with whatever
# permissions your app needs.
# See https://developers.facebook.com/docs/reference/api/permissions/
# for a full list of permissions
FACEBOOK_SCOPE = 'user_likes,user_photos,user_photo_video_tags'
FACEBOOK_APP_ID = '233415936718890'
FACEBOOK_SECRET = 'bdfb61838609fea5cbf9420296cc7d09'

unless FACEBOOK_APP_ID && FACEBOOK_SECRET
  abort("missing env vars: please set FACEBOOK_APP_ID and FACEBOOK_SECRET with your app credentials")
end

#=begin
before do
  # HTTPS redirect
  unless ((settings.environment == :production) && (request.scheme != 'https'))
    redirect "https://#{request.env['HTTP_HOST']}"
  end
end
#=end


helpers do
  def url(path)
    base = "#{request.scheme}://#{request.env['HTTP_HOST']}"
    base + path
  end

  def post_to_wall_url
    "https://www.facebook.com/dialog/feed?redirect_uri=#{url("/close")}&display=popup&app_id=#{@app.id}";
  end

  def send_to_friends_url
    "https://www.facebook.com/dialog/send?redirect_uri=#{url("/close")}&display=popup&app_id=#{@app.id}&link=#{url('/')}";
  end

  def authenticator
    @authenticator ||= Mogli::Authenticator.new(FACEBOOK_APP_ID, FACEBOOK_SECRET, url("/auth/facebook/callback"))
  end

  def first_column(item, collection)
    return ' class="first-column"' if collection.index(item)%4 == 0
  end
end

# the facebook session expired! reset ours and restart the process
error(Mogli::Client::HTTPException) do
  session[:at] = nil
  redirect '/auth/facebook'
end



# Extract the connection string for the rabbitmq service from the
# service information provided by Cloud Foundry in an environment
# variable.
def amqp_url
  services = JSON.parse(ENV['VCAP_SERVICES'], :symbolize_names => true)
  url = services.values.map do |srvs|
    srvs.map do |srv|
      if srv[:label] =~ /^rabbitmq-/
        srv[:credentials][:url]
      else
        []
      end
    end
  end.flatten!.first
end

# Opens a client connection to the RabbitMQ service, if one isn't
# already open.  This is a class method because a new instance of
# the controller class will be created upon each request.  But AMQP
# connections can be long-lived, so we would like to re-use the
# connection across many requests.
def client
  unless $client
    c = Bunny.new(amqp_url)
    c.start
    $client = c

    # We only want to accept one un-acked message
    $client.qos :prefetch_count => 1
  end
  $client
end

# Return the "nameless exchange", pre-defined by AMQP as a means to
# send messages to specific queues.  Again, we use a class method to
# share this across requests.
def nameless_exchange
  $nameless_exchange ||= client.exchange('')
end

# Return a queue named "messages".  This will create the queue on
# the server, if it did not already exist.  Again, we use a class
# method to share this across requests.
def messages_queue
  $messages_queue ||= client.queue("messages")
end

def take_session key
  res = session[key]
  session[key] = nil
  res
end



get "/" do

  redirect "/auth/facebook" unless session[:at]
  @client = Mogli::Client.new(session[:at])

  # limit queries to 15 results
  @client.default_params[:limit] = 15

  @app  = Mogli::Application.find(FACEBOOK_APP_ID, @client) ##??
  @user = Mogli::User.find("me", @client) ##me??

  # access friends, photos and likes directly through the user instance
  @friends = @user.friends[0, 4]
  @photos  = @user.photos[0, 16]
  @likes   = @user.likes[0, 4]

  # for other data you can always run fql
  @friends_using_app = @client.fql_query("SELECT uid, name, is_app_user, pic_square FROM user WHERE uid in (SELECT uid2 FROM friend WHERE uid1 = me()) AND is_app_user = 1")

  #from emckitty
  @published = take_session(:published)
  @got = take_session(:got)

  erb :index

end

# used by Canvas apps - redirect the POST to be a regular GET
post "/" do
  redirect to('/')
end

# used to close the browser window opened to post to wall/send to friends
get "/close" do
  "<body onload='window.close();'/>"
end

get "/auth/facebook" do
  session[:at]=nil
  redirect to(authenticator.authorize_url(:scope => FACEBOOK_SCOPE, :display => 'page')) ##fb redirect problem occurs
end

get '/auth/facebook/callback' do
  client = Mogli::Client.create_from_code_and_authenticator(params[:code], authenticator)
  session[:at] = client.access_token
  redirect to('/')
end

get '/new' do #go to welcome and get id&secret
  
  #step1 generate files and add contents
  #step2 copy zip file and add in text files
  #step3 accept params to make ruby file
  
  erb :welcome
end

post '/getty' do #@welcome page
  @ffids = params[:ffid]
  @ffses = params[:ffse]  
  Dir.chdir("public/res")
  
  newfile = File.new("app.rb","w+")
  File.foreach("apphead.rb"){ |line| newfile.puts(line)}
  newfile.puts("FACEBOOK_APP_ID = \'#{@ffids}\'")
  newfile.puts("FACEBOOK_SECRET = \'#{@ffses}\'")
  File.foreach("appbody.rb"){ |line| newfile.puts(line)}
  newfile.close
  
  Zip::ZipFile.open('yourfacebookapptemplate.zip') do |zf|
    zf.replace("app.rb", "./app.rb")
  end
  #File.delete("app.rb")
  Dir.chdir("../..")
  #content_type 'application/octet-stream'
  #File.read('public/res/template.zip')
  redirect to("res/yourfacebookapptemplate.zip")
end

post '/publish' do
  # Send the message from the form's input box to the "messages"
  # queue, via the nameless exchange.  The name of the queue to
  # publish to is specified in the routing key.
  nameless_exchange.publish params[:message], :content_type => "text/plain",
                            :key => "messages"
  # Notify the user that we published.
  session[:published] = true
  redirect to('/')
end

post '/get' do
  session[:got] = :queue_empty

  # Wait for a message from the queue
  messages_queue.subscribe(:ack => true, :timeout => 10,
                           :message_max => 1) do |msg|
    # Show the user what we got
    session[:got] = msg[:payload]
  end

  redirect to('/')
end
