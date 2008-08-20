require 'contacts'
require 'cgi'
require 'net/http'
require 'net/https'
require 'rubygems'
require 'hpricot'
require 'time'
require 'zlib'
require 'stringio'

module Contacts
  # == Fetching Google Contacts
  # 
  # Web applications should use
  # AuthSub[http://code.google.com/apis/contacts/developers_guide_protocol.html#auth_sub]
  # proxy authentication to get an authentication token for a Google account.
  # 
  # First, get the user to follow the following URL:
  # 
  #   Contacts::Google.authentication_url('http://mysite.com/invite')
  #
  # After he authenticates successfully, Google will redirect him back to the target URL
  # (specified as argument above) and provide the token GET parameter. Use it to create a
  # new instance of this class and request the contact list:
  #
  #   gmail = Contacts::Google.new('example@gmail.com', params[:token])
  #   contacts = gmail.contacts
  #   #-> [ ['Fitzgerald', 'fubar@gmail.com', 'fubar@example.com'],
  #         ['William Paginate', 'will.paginate@gmail.com'], ...
  #         ]
  #
  # == Storing a session token
  #
  # The basic token that you will get after the user has authenticated on Google is valid
  # for only one request. However, you can specify that you want a session token which
  # doesn't expire:
  # 
  #   Contacts::Google.authentication_url('http://mysite.com/invite', :session => true)
  #
  # When the user authenticates, he will be redirected back with a token which still isn't
  # a session token, but can be exchanged for one!
  #
  #   token = Contacts::Google.sesion_token(params[:token])
  #
  # Now you have a permanent token. Store it with other user data so you can query the API
  # on his behalf without him having to authenticate on Google each time.
  class Google
    DOMAIN      = 'www.google.com'
    AuthSubPath = '/accounts/AuthSub' # all variants go over HTTPS
    ClientLogin = '/accounts/ClientLogin'
    FeedsPath   = '/m8/feeds/contacts/'
    
    # default options for #authentication_url
    def self.authentication_url_options
      @authentication_url_options ||= {
        :scope => "http://#{DOMAIN}#{FeedsPath}",
        :secure => false,
        :session => false
      }
    end
    
    # default options for #client_login
    def self.client_login_options
      @client_login_options ||= {
        :accountType => 'GOOGLE',
        :service => 'cp',
        :source => 'Contacts-Ruby'
      }
    end

    # URL to Google site where user authenticates. Afterwards, Google redirects to your
    # site with the URL specified as +target+.
    #
    # Options are:
    # * <tt>:scope</tt> -- the AuthSub scope in which the resulting token is valid
    #   (default: "http://www.google.com/m8/feeds/contacts/")
    # * <tt>:secure</tt> -- boolean indicating whether the token will be secure
    #   (default: false)
    # * <tt>:session</tt> -- boolean indicating if the token can be exchanged for a session token
    #   (default: false)
    def self.authentication_url(target, options = {})
      params = authentication_url_options.merge(options)
      params[:next] = target
      query = query_string(params)
      "https://#{DOMAIN}#{AuthSubPath}Request?#{query}"
    end
    
    # Constructs a query string from a Hash object
    def self.query_string(params)
      params.inject([]) do |all, pair|
        key, value = pair
        unless value.nil?
          value = case value
            when TrueClass;  '1'
            when FalseClass; '0'
            else value
            end
          
          all << "#{CGI.escape(key.to_s)}=#{CGI.escape(value.to_s)}"
        end
        all
      end.join('&')
    end

    # Makes an HTTPS request to exchange the given token with a session one. Session
    # tokens never expire, so you can store them in the database alongside user info.
    #
    # Returns the new token as string or nil if the parameter couldn't be found in response
    # body.
    def self.session_token(token)
      response = Net::HTTP.start(DOMAIN) do |google|
        google.use_ssl
        google.verify_mode = OpenSSL::SSL::VERIFY_NONE
        google.get(AuthSubPath + 'SessionToken', auth_headers(token))
      end

      pair = response.body.split(/\n/).detect { |p| p.index('Token=') == 0 }
      pair.split('=').last if pair
    end
    
    # Alternative to AuthSub: using email and password.
    def self.client_login(email, password)
      response = Net::HTTP.start(DOMAIN) do |google|
        google.use_ssl
        google.verify_mode = OpenSSL::SSL::VERIFY_NONE
        query = query_string(client_login_options.merge(:Email => email, :Passwd => password))
        google.post(ClientLogin, query)
      end

      pair = response.body.split(/\n/).detect { |p| p.index('Auth=') == 0 }
      pair.split('=').last if pair
    end
    
    attr_reader :user, :token, :headers
    attr_accessor :projection

    # A token is required here. By default, an AuthSub token from
    # Google is one-time only, which means you can only make a single request with it.
    def initialize(token, user_id = 'default')
      @user    = user_id.to_s
      @token   = token.to_s
      @headers = { 'Accept-Encoding' => 'gzip' }.update(self.class.auth_headers(@token))
      @projection = 'thin'
    end

    def get(params) # :nodoc:
      response = Net::HTTP.start(DOMAIN) do |google|
        path = FeedsPath + CGI.escape(@user)
        google_params = translate_parameters(params)
        query = self.class.query_string(google_params)
        google.get("#{path}/#{@projection}?#{query}", @headers)
      end

      raise FetchingError.new(response) unless response.is_a? Net::HTTPSuccess
      response
    end

    # Timestamp of last update. This value is available only after the XML
    # document has been parsed; for instance after fetching the contact list.
    def updated_at
      @updated_at ||= Time.parse @updated_string if @updated_string
    end

    # Timestamp of last update as it appeared in the XML document
    def updated_at_string
      @updated_string
    end

    # Fetches, parses and returns the contact list.
    #
    # ==== Options
    # * <tt>:limit</tt> -- use a large number to fetch a bigger contact list (default: 200)
    # * <tt>:offset</tt> -- 0-based value, can be used for pagination
    # * <tt>:order</tt> -- currently the only value support by Google is "lastmodified"
    # * <tt>:descending</tt> -- boolean
    # * <tt>:updated_after</tt> -- string or time-like object, use to only fetch contacts
    #   that were updated after this date
    def contacts(options = {})
      params = { :limit => 200 }.update(options)
      response = get(params)
      parse_contacts response_body(response)
    end

    protected
      
      def response_body(response)
        unless response['Content-Encoding'] == 'gzip'
          response.body
        else
          gzipped = StringIO.new(response.body)
          Zlib::GzipReader.new(gzipped).read
        end
      end
      
      def parse_contacts(body)
        doc = Hpricot::XML body
        entries = []
        
        if updated_node = doc.at('/feed/updated')
          @updated_string = updated_node.inner_text
        end
        
        (doc / '/feed/entry').each do |entry|
          email_nodes = entry / 'gd:email[@address]'
          
          unless email_nodes.empty?
            title_node = entry.at('/title')
            name = title_node ? title_node.inner_text : nil
            
            person = email_nodes.inject [name] do |p, e|
              p << e['address'].to_s
            end
            entries << person
          end
        end

        entries
      end

      def translate_parameters(params)
        params.inject({}) do |all, pair|
          key, value = pair
          unless value.nil?
            key = case key
              when :limit
                'max-results'
              when :offset
                value = value.to_i + 1
                'start-index'
              when :order
                all['sortorder'] = 'descending' if params[:descending].nil?
                'orderby'
              when :descending
                value = value ? 'descending' : 'ascending'
                'sortorder'
              when :updated_after
                value = value.strftime("%Y-%m-%dT%H:%M:%S%Z") if value.respond_to? :strftime
                'updated-min'
              else key
              end
            
            all[key] = value
          end
          all
        end
      end
      
      def self.auth_headers(token)
        { 'Authorization' => %(AuthSub token="#{token}") }
      end
  end
end
