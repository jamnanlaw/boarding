require "spaceship"
require "gmail"

class AddTesterResponse
  attr_accessor :message
  attr_accessor :type
  attr_accessor :url
end  

class BoardingService
  include AbstractController::Translation

  attr_accessor :app
  attr_accessor :app_id
  attr_accessor :user
  attr_accessor :password
  attr_accessor :tester_group_names
  attr_accessor :is_demo
  attr_accessor :itc_token
  attr_accessor :itc_closed_text
  attr_accessor :imprint_url
  attr_accessor :gmail_username
  attr_accessor :gmail_password

  def initialize(app_id: ENV["ITC_APP_ID"],
                   user: ENV["ITC_USER"] || ENV["FASTLANE_USER"],
               password: ENV["ITC_PASSWORD"] || ENV["FASTLANE_PASSWORD"],
     tester_group_names: ENV["ITC_APP_TESTER_GROUPS"])
    @app_id = app_id
    @user = user
    @password = password

    groups = tester_group_names.to_s.split(/\s*,\s*/)
    @tester_group_names = groups unless groups.empty?

    @is_demo = ENV["ITC_IS_DEMO"]
    @itc_token = ENV["ITC_TOKEN"]
    @itc_closed_text = ENV["ITC_CLOSED_TEXT"]
    @imprint_url = ENV["IMPRINT_URL"]
    @gmail_username = ENV["ITC_GMAIL_USER"]  # in format of name, @gmail.com is not necessary
    @gmail_password = ENV["ITC_GMAIL_PASSWORD"]
    ensure_values
  end

  def add_tester(email, first_name, last_name)
    add_tester_response = AddTesterResponse.new
    add_tester_response.type = "danger"

    #tester = find_app_tester(email: email, app: app)

    dynamic_gmail = @gmail_username + '+' + email.gsub(/[@.]/, '@' => '_', '.' => '_') + '@gmail.com'
    Rails.logger.info "dynamic gmail is: #{dynamic_gmail}"

    tester = find_app_tester(email: dynamic_gmail, app: app)

    if tester
      add_tester_response.message = t(:message_email_exists)
    else
      tester = create_tester(
        email: dynamic_gmail,
        first_name: first_name,
        last_name: last_name,
        app: app
      )
      if true || testing_is_live? # TODO: remove true and test new train system
        add_tester_response.message = t(:message_success_live)
      else
        add_tester_response.message = t(:message_success_pending)
      end
      add_tester_response.type = "success"
    end

    begin
      groups = Spaceship::TestFlight::Group.add_tester_to_groups!(tester: tester, app: app, groups: tester_group_names)
      # if tester.kind_of?(Spaceship::Tunes::Tester::Internal)
      #   Rails.logger.info "Successfully added tester to app #{app.name}"
      # else
        # tester was added to the group(s) in the above add_tester_to_groups() call, now we need to let the user know which group(s)
        if tester_group_names
          group_names = groups.map(&:name).join(", ")
          Rails.logger.info "Successfully added tester to group(s): #{group_names} in app: #{app.name}"
        else
          Rails.logger.info "Successfully added tester to the default tester group in app: #{app.name}"
        end
      # end

    rescue => ex
      Rails.logger.error "Could not add #{tester.email} to app: #{app.name}"
      raise ex
    end

     # read gmail message
     begin
      url = get_url_from_gmail(dyn_gmail: dynamic_gmail)
      Rails.logger.info "Message is: #{url}"
      add_tester_response.url = url
    rescue => ex
      Rails.logger.error "The TestFlight message cannot be shown."
      raise ex
    end

    return add_tester_response
  end

  private

    def create_tester(email: nil, first_name: nil, last_name: nil, app: nil)
      current_user = Spaceship::Members.find(Spaceship::Tunes.client.user)
      # if current_user.admin? || current_user.app_manager?
        Spaceship::TestFlight::Tester.create_app_level_tester(app_id: app.apple_id,
                                                          first_name: first_name,
                                                           last_name: last_name,
                                                               email: email)
        tester = Spaceship::TestFlight::Tester.find(app_id: app.apple_id, email: email)
        Rails.logger.info "Successfully added tester: #{email} to app: #{app.name}"
      # else
      #   raise "Current account doesn't have permission to create a tester"
      # end

      return tester
    rescue => ex
      Rails.logger.error "Could not create tester #{email}"
      raise ex
    end

    def find_app_tester(email: nil, app: nil)
      # current_user = Spaceship::Members.find(Spaceship::Tunes.client.user)
      # if current_user.admin? || current_user.app_manager?
      #   unless app
      #     raise "You must define what app this tester (#{email}) should be added to"
      #   end
        tester = Spaceship::TestFlight::Tester.find(app_id: app.apple_id, email: email)
      # else
      #   raise "Account #{current_user.email_address} doesn't have a role that is allowed to administer app testers, current roles: #{current_user.roles}"
      #   tester = nil
      # end

      if tester
        Rails.logger.info "Found existing tester #{email}"
      end

      return tester
    end
    def ensure_values
      error_message = []

      error_message << "Environment variable `ITC_APP_ID` required" if @app_id.to_s.length == 0
      error_message << "Environment variable `ITC_USER` or `FASTLANE_USER` required" if @user.to_s.length == 0
      error_message << "Environment variable `ITC_PASSWORD` or `FASTLANE_PASSWORD`" if @password.to_s.length == 0
      raise error_message.join("\n") if error_message.length > 0

      spaceship = Spaceship::Tunes.login(@user, @password)
      spaceship.select_team

      @app ||= Spaceship::Tunes::Application.find(@app_id)      
      raise "Could not find app with ID #{app_id}" if @app.nil?

      if tester_group_names
        test_flight_groups = Spaceship::TestFlight::Group.filter_groups(app_id: @app.apple_id)
        test_flight_group_names = test_flight_groups.map { |group| group.name }.to_set
        tester_group_names.select do |group_name|
          next if test_flight_group_names.include?(group_name)
          error_message << "TestFlight missing group `#{group_name}`, You need to first create this group in iTunes Connect."
        end
      end

      raise error_message.join("\n") if error_message.length > 0
    end

    def testing_is_live? # TODO: clean this when Spaceship::TestFlight::BuildTrains has more attributes
      app.build_trains(platform: 'ios').values.each do |trains|
        # if train.external_testing_enabled
        #   train.builds.each do |build|
        trains.each do |build|
          return true if build.active?
        end
        #   end
        # end
      end
      return false
    end

    def get_url_from_gmail(dyn_gmail: nil)

      gmail = Gmail.connect(@gmail_username, @gmail_password)
      # play with your gmail...

      #toemail = "`#{@gmail_username}`.#{signupemail.sub!('@'.'.')}@gmail.com"
      waitcount = 5
      url = ""
      start = "https://beta.itunes.apple.com"
      last_char = "'"
      loop do
        sleep(5) # wait 5 seconds
        message = gmail.inbox.emails(:unread, :to => dyn_gmail).first
        if message
          body = message.html
          beta_url = body[/#{start}(.*?)#{last_char}/m, 1]
          url = start + '/' + beta_url.unpack('M')[0]
          gmail.deliver do
            to signupemail
            subject message.subject
            text_part do
              body message.text
            end
            html_part do
              content_type 'text/html; charset=UTF-8'
              body message.html
            end
          end
          break
        else
          waitcount -= 1
          break if waitcount == 0
        end
      end
      gmail.logout
      return url
    end

end
