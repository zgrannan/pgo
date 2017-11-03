package pgo;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.Arrays;
import java.util.HashMap;

// Wraps options related to networking in the generated Go code.
// Networking related options are defined in the JSON configuration
// file and specify details about message channels (e.g., IP addresses
// and ports. See the +sample.json+ file included in this repository
// for an example of how to define these properties.

// Networking options involve a number of concepts: shared state
// management, the separation of different processes in the network, and
// how they are connected together. Each of these components are handled
// by separate classes (see documentation for the inner classes below).
//
// If there are semantic errors in the configuration of any of these
// aspects, the associated class throws an exception. That is caught
// by the +PGoOptions+ class (when processing user input) which is then able
// to display an appropriate error message to the user.
public class PGoNetOptions {

	// A process declared in the configuration file is expected to match
	// a PlusCal +process+ definition. When networking is enabled, we need
	// to know the ID of the process (its declared name in the PlusCal
	// algorithm), as well as the address-related options (IP and port number).
	private class Process {
		public String id;
		public String role;
		public String host;
		public int port;

		public Process(JSONObject config) throws PGoOptionException {
			this.id = config.getString("id");
			this.role = config.getString("role");
			this.host = config.getString("host");
			this.port = config.getInt("port");

			validate();
		}

		public void validate() throws PGoOptionException {
			if (id.isEmpty()) {
				throw new PGoOptionException("all processes need to have an ID");
			}
		}

	}

	// This class encapsulates state management options. Since processes now run in
	// separate hosts, shared state needs to be mapped either to a centralized source
	// or distributed among a number of nodes in the network.
	//
	// This class ensures that the options provided in the configuration file make
	// sense, i.e., whether they use a known/supported state management strategy.
	private class StateOptions {
		private static final String STATE_CENTRALIZED = "centralized";
		private final String[] STATE_STRATEGIES = {
				STATE_CENTRALIZED
		};

		private static final String DEFAULT_STATE_STRATEGY = STATE_CENTRALIZED;

		public String strategy;
		public String host;
		public int port;

		public StateOptions(JSONObject config) throws PGoOptionException {
			this.strategy = config.getString("strategy");
			if (this.strategy == null) {
				this.strategy = DEFAULT_STATE_STRATEGY;
			}

			this.host = config.getString("host");
			this.port = config.getInt("port");

			validate();
		}

		private void validate() throws PGoOptionException {
			if (!Arrays.asList(STATE_STRATEGIES).contains(this.strategy)) {
				throw new PGoOptionException("Invalid state strategy: " + this.strategy);
			}
		}
	}

	// A channel is a communication mechanism that allows two processes (see +Process+ class)
	// to communicate. PlusCal does not have the concept of a communication channel -
	// process communication in a PlusCal algorithm typically involves updating a shared
	// tuple of messages.
	//
	// The +channels+ option in the configuration file, therefore, allows the developer to
	// specify the tuples that represent these communication channels. Currently, only
	// point-to-point communication is supported (i.e., no broadcast/multicast/anycast).
	private class Channel {
		public String name;
		public Process[] processes;

		// channels connect two processes
		private static final int PROCESSES_PER_CHANNEL = 2;

		public Channel(JSONObject config) throws PGoOptionException {
			this.name = config.getString("name");
			JSONArray p = config.getJSONArray("processes");
			int i;

			if (p.length() != PROCESSES_PER_CHANNEL) {
				throw new PGoOptionException("Channel \"" + name + "\": must have 2 processes");
			}


			processes = new Process[PROCESSES_PER_CHANNEL];
			for (i = 0; i < PROCESSES_PER_CHANNEL; i++) {
				processes[i] = new Process(p.getJSONObject(i));
			}

			validate();
		}

		private void validate() throws PGoOptionException {
			if (processes[0].id.equals(processes[1].id)) {
				throw new PGoOptionException("Processes should have different ids");
			}
		}
	}

	// allows the developer to easily turn off networking by setting this parameter to +false+
	private boolean enabled = false;

	private StateOptions stateOptions;
	private HashMap<String, Channel> channels = new HashMap<String, Channel>();

	// This constructor expects a +JSONObject+ as parameter - this should be the data structure
	// representing the entire configuration file. Separate parts of the configuration file
	// are then passed to specific components (see inner classes above), each of which has
	// the responsibility to verify whether the configuration is valid.
	public PGoNetOptions(JSONObject config) throws PGoOptionException {
		JSONObject netConfig = config.getJSONObject("networking");
		JSONObject stateConfig = netConfig.getJSONObject("state");
		JSONArray channelsConfig = netConfig.getJSONArray("channels");
		int i;

		if (!netConfig.getBoolean("enabled")) {
			enabled = false;
			return;
		}

		enabled = true;
		stateOptions = new StateOptions(stateConfig);

		for (i = 0; i < channelsConfig.length(); i++) {
			JSONObject channel = (JSONObject) channelsConfig.get(i);
			String name = channel.getString("name");

			if (channels.get(name) != null) {
				throw new PGoOptionException("Process with name \"" + name + "\" already exists");
			}

			channels.put(name, new Channel(channel));
		}
	}

	public boolean isEnabled() {
		return this.enabled;
	}
}
