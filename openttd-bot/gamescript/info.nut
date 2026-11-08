/*
 * ChatBot Game Script - info file.
 *
 * Executes building commands sent by the ottd-chatbot bridge over the admin
 * port, acting on behalf of a player's company via GSCompanyMode.
 */
class ChatBotInfo extends GSInfo {
	function GetAuthor()      { return "ottd-chatbot"; }
	function GetName()        { return "ChatBot"; }
	function GetShortName()   { return "CHBT"; }
	function GetDescription() { return "Builds rail lines and truck routes for players on request. Driven by the ottd-chatbot admin-port bridge, which turns natural-language chat into commands."; }
	function GetVersion()     { return 1; }
	function GetDate()        { return "2026-11-08"; }
	function CreateInstance() { return "ChatBot"; }
	function GetAPIVersion()  { return "15"; }
	function GetURL()         { return ""; }
	function IsDeveloperOnly() { return false; }

	function GetSettings() {
		AddSetting({
			name = "max_pf_iterations",
			description = "Pathfinder effort (nodes explored before giving up)",
			min_value = 5000,
			max_value = 500000,
			default_value = 80000,
			step_size = 5000,
			flags = CONFIG_INGAME
		});
		AddSetting({
			name = "max_bridge_length",
			description = "Longest bridge the pathfinder may build",
			min_value = 2,
			max_value = 30,
			default_value = 10,
			step_size = 1,
			flags = CONFIG_INGAME
		});
	}
}

RegisterGS(ChatBotInfo());
