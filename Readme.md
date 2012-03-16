Facebook/Force.com/Heroku sample app -- Ruby
============================================

This is a sample Facebook app showing use of the Force.com REST API, written in Ruby, designed for deployment to [Heroku](http://www.heroku.com/).

This app was shown at my Cloudstock 2012 session 'Create a Force.com-Powered Facebook App on Heroku'. [Presentation slides](https://github.com/metadaddy-sfdc/Facebook-Sinatra-Force.com-Heroku/blob/master/CS12_Heroku_Facebook.pdf?raw=true).

Run locally
-----------

Install dependencies:

    bundle install

[Create an app on Facebook](https://developers.facebook.com/apps) and set the Website URL to `http://localhost:5000/`.

Copy the App ID and Secret from the Facebook app settings page into your `.env`:

    echo FACEBOOK_APP_ID=12345 >> .env
    echo FACEBOOK_SECRET=abcde >> .env
    
[Create a remote access app in your org](https://login.salesforce.com/help/doc/en/remoteaccess_about.htm) on Force.com and set the Website URL to `http://localhost:5000/`.

Copy the Consumer Key and Secret, and the username and password of an API user, from the Force.com remote app settings page into your `.env`:

        echo CLIENT_ID=67890 >> .env
        echo CLIENT_SECRET=fghij >> .env
        echo USERNAME=apiuser@example.com >> .env
        echo PASSWORD=******** >> .env

Launch the app with [Foreman](http://blog.daviddollar.org/2011/05/06/introducing-foreman.html):

    foreman start

Deploy to Heroku
----------------

If you prefer to deploy yourself, push this code to a new Heroku app on the Cedar stack, then copy the IDs, secrets and credentials into your config vars:

    heroku create --stack cedar
    git push heroku master
    heroku config:add FACEBOOK_APP_ID=12345 FACEBOOK_SECRET=abcde \
        CLIENT_ID=67890 CLIENT_SECRET=fghij USERNAME=apiuser@example.com \
        PASSWORD=********

Enter the URL for your Heroku app into the Website URL section of the Facebook app settings page, then you can visit your app on the web.

