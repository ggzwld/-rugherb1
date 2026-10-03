import { useState, useEffect, useRef } from "react";
import { Link, useNavigate } from "react-router-dom";
import { Button } from "../components/ui/button";
import { BillingTab } from "./components/BillingTab";
import { supabase } from "../lib/supabase";
import { useToast } from "../hooks/use-toast";
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
} from "../components/ui/card";
import { Input } from "../components/ui/input";
import { Label } from "../components/ui/label";
import { Badge } from "../components/ui/badge";
import { Avatar, AvatarFallback, AvatarImage } from "../components/ui/avatar";
import { Textarea } from "../components/ui/textarea";
import {
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger,
} from "../components/ui/tabs";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "../components/ui/select";
import { Switch } from "../components/ui/switch";
import { Progress } from "../components/ui/progress";
import { Separator } from "../components/ui/separator";
import {
  Briefcase,
  Gift,
  Star,
  Heart,
  Calendar,
  CreditCard,
  Download,
  Settings,
  Bell,
  User,
  Mail,
  Phone,
  MapPin,
  Camera,
  Wallet,
  TrendingUp,
  Award,
  Share2,
  Copy,
  Receipt,
  History,
  CheckCircle,
  Clock,
  DollarSign,
  Target,
  Users,
  BarChart3,
  Zap,
  Edit,
  Eye,
  EyeOff,
} from "lucide-react";
import { format, addDays } from "date-fns";

type RewardsSummary = {
  organizationId: string;
  organizationName: string;
  programName: string;
  availablePoints: number;
  lifetimePoints: number;
  enrolled: boolean;
  debtPoints: number;
  referralCode: string | null;
  referrals: { total: number; qualified: number; pending: number; pointsEarned: number };
  entries: Array<{ id: string; entryType: string; pointsDelta: number; description: string; createdAt: string }>;
  policy: {
    pointsPer1000Ugx: number;
    guestReferralMinimumUgx: number;
    referrerBonusPoints: number;
    inviteeBonusPoints: number;
    taskApprovalPoints: number;
    monthlyTaskPointsCap: number;
    ugxValuePerPoint: number;
    redemptionEnabled: boolean;
    pointsExpire: boolean;
    programEnabled: boolean;
  };
};

const ServicesProfilePage = () => {
  const navigate = useNavigate();
  const { toast } = useToast();
  const [activeTab, setActiveTab] = useState("dashboard");
  const [isEditing, setIsEditing] = useState(false);
  const [showPerformanceDetails, setShowPerformanceDetails] = useState(false);
  const [dataLoaded, setDataLoaded] = useState(false);
  const [userRole, setUserRole] = useState<'guest' | 'manager' | 'service_provider' | null>(null);
  const [rewardsPrograms, setRewardsPrograms] = useState<RewardsSummary[]>([]);
  const [selectedRewardsOrganization, setSelectedRewardsOrganization] = useState("");
  const [rewardsLoadError, setRewardsLoadError] = useState(false);
  const saveTimeoutsRef = useRef<Record<string, NodeJS.Timeout>>({});
  const userIdRef = useRef<string | null>(null);

  // User data from database
  const [userData, setUserData] = useState({
    organizationName: "",
    hotelStarRating: "",
    firstName: "",
    lastName: "",
    email: "",
    phone: "",
    birthday: "",
    location: "",
    memberSince: new Date().toISOString().split('T')[0],
    profilePicture: "",
    preferences: {
      roleType: "manager",
      notificationType: "detailed",
      taskCategory: "all",
      theme: "modern",
      notifications: {
        tasks: true,
        reports: true,
        alerts: true,
        newsletter: false,
      },
    },
  });

  // Save field to database with debounce
  const saveFieldToDatabase = async (fieldName: string, value: string | null) => {
    if (!userIdRef.current) return;

    // Clear existing timeout for this field
    if (saveTimeoutsRef.current[fieldName]) {
      clearTimeout(saveTimeoutsRef.current[fieldName]);
    }

    // Debounce the save by 500ms
    saveTimeoutsRef.current[fieldName] = setTimeout(async () => {
      try {
        const dbFieldName = fieldName === 'firstName' ? 'first_name' :
                           fieldName === 'lastName' ? 'last_name' :
                           fieldName === 'organizationName' ? 'organization_name' :
                           fieldName === 'hotelStarRating' ? 'hotel_star_rating' : fieldName;

        const { error } = await supabase
          .from("user_profiles")
          .update({ [dbFieldName]: fieldName === 'hotelStarRating' && value ? Number(value) : value })
          .eq("user_id", userIdRef.current);
        if (error) throw error;
      } catch (error) {
        console.error(`Error saving ${fieldName}:`, error);
        toast({ title: "Profile changes could not be saved", description: "Check your connection and try again.", variant: "destructive" });
      }
    }, 500);
  };

  // Fetch user profile data from Supabase
  useEffect(() => {
    const fetchUserProfile = async () => {
      try {
        const { data: { user } } = await supabase.auth.getUser();

        if (!user) {
          navigate("/login");
          return;
        }

        userIdRef.current = user.id;

        const { data: profile, error: profileError } = await supabase
          .from("user_profiles")
          .select("*")
          .eq("user_id", user.id)
          .maybeSingle();

        if (profileError) {
          console.error("Unable to load user profile:", profileError);
        }

        const metadata = user.user_metadata || {};
        let resolvedProfile = profile;

        if (!resolvedProfile && !profileError) {
          const { data: createdProfile, error: createProfileError } = await supabase
            .from("user_profiles")
            .insert({
              user_id: user.id,
              organization_name: metadata.organization_name || null,
              hotel_star_rating: metadata.hotel_star_rating ? Number(metadata.hotel_star_rating) : null,
              email: user.email || "",
              first_name: metadata.first_name || "",
              last_name: metadata.last_name || "",
              phone: metadata.phone || null,
              role: metadata.role || "guest",
              service_type: metadata.service_type || null,
              service_category: metadata.service_category || null,
              menu_access_role: metadata.menu_access_role || "none",
              menu_access_approved: false,
            })
            .select("*")
            .single();

          if (createProfileError) {
            console.error("Unable to create missing user profile:", createProfileError);
          } else {
            resolvedProfile = createdProfile;
          }
        }

        const resolvedRole = resolvedProfile?.role ||
          (metadata.role === "manager" ? "manager" : "service_provider");
        setUserRole(resolvedRole);
        setUserData((prev) => ({
          ...prev,
          organizationName: resolvedProfile?.organization_name || metadata.organization_name || "",
          hotelStarRating: resolvedProfile?.hotel_star_rating ? String(resolvedProfile.hotel_star_rating) : "",
          firstName: resolvedProfile?.first_name || metadata.first_name || "",
          lastName: resolvedProfile?.last_name || metadata.last_name || "",
          email: user.email || "",
          phone: resolvedProfile?.phone || metadata.phone || "",
          birthday: resolvedProfile?.birthday || "",
          location: resolvedProfile?.location || "",
          memberSince: resolvedProfile?.created_at ? resolvedProfile.created_at.split('T')[0] : new Date().toISOString().split('T')[0],
          profilePicture: resolvedProfile?.profile_picture || "",
        }));
        const { data: rewards, error: rewardsError } = await supabase.rpc("get_my_hotel_loyalty_programs");
        if (rewardsError) {
          console.error("Unable to load hotel rewards programs:", rewardsError);
          setRewardsLoadError(true);
        } else {
          const programs = (rewards || []) as RewardsSummary[];
          setRewardsPrograms(programs);
          setSelectedRewardsOrganization((current) =>
            programs.some((program) => program.organizationId === current) ? current : programs[0]?.organizationId || "",
          );
          setRewardsLoadError(false);
        }
        setDataLoaded(true);
      } catch (error) {
        console.error("Unable to initialize profile:", error);
        setDataLoaded(true);
      }
    };

    fetchUserProfile();
  }, [navigate]);

  // Cleanup timeouts on unmount
  useEffect(() => {
    return () => {
      Object.values(saveTimeoutsRef.current).forEach(timeout => clearTimeout(timeout));
    };
  }, []);

  const performanceData = {
    currentRating: 4.8,
    ratingOutOf: 5.0,
    tasksCompleted: 247,
    tasksInProgress: 12,
    avgCompletionTime: "2.3 days",
    qualityScore: 96,
    nextBadge: "Platinum Service Partner",
    badgeProgress: 83,
    pointsToNextBadge: 150,
    lifetimeTasks: 247,
    performanceTier: "Gold Service Partner",
    benefits: [
      "Priority task allocation",
      "15% performance bonus",
      "Featured service listing",
      "Extended support hours",
      "Direct account manager",
      "Training & development access",
    ],
    nextTierBenefits: [
      "All Gold benefits",
      "25% performance bonus",
      "Premium service listing",
      "24/7 dedicated support",
      "Business development manager",
      "Custom partnership agreement",
    ],
  };

  const rewardsSummary = rewardsPrograms.find((program) => program.organizationId === selectedRewardsOrganization) || null;

  const recentActivities = (rewardsSummary?.entries || []).map((entry) => ({
    id: entry.id,
    type: entry.pointsDelta < 0 ? "reversal" : entry.entryType.includes("referral") ? "referral" : "earning",
    description: entry.description,
    points: `${entry.pointsDelta > 0 ? "+" : ""}${entry.pointsDelta.toLocaleString()} pts`,
    date: entry.createdAt,
    status: "posted",
  }));

  const activeOpportunities = [
    {
      id: "task-reward",
      title: "Manager-approved task reward",
      description: `${rewardsSummary?.policy.taskApprovalPoints ?? 50} points per approved task, up to ${rewardsSummary?.policy.monthlyTaskPointsCap ?? 500} points each month`,
      type: "task",
      emoji: "✓",
    },
    {
      id: "referral-reward",
      title: "Qualified referral reward",
      description: `${rewardsSummary?.policy.referrerBonusPoints ?? 250} points after the referred member qualifies`,
      type: "referral",
      emoji: "👥",
    },
  ];

  const taskEarningActivities = [
    {
      activity: "Eligible purchases",
      points: `${rewardsSummary?.policy.pointsPer1000Ugx ?? 1} point per UGX 1,000 of eligible net spend`,
      icon: CreditCard,
    },
    {
      activity: "Manager-approved tasks",
      points: `${rewardsSummary?.policy.taskApprovalPoints ?? 50} points, capped at ${rewardsSummary?.policy.monthlyTaskPointsCap ?? 500} points per month`,
      icon: CheckCircle,
    },
    {
      activity: "Qualified referrals",
      points: `${rewardsSummary?.policy.referrerBonusPoints ?? 250} points for each qualified referral`,
      icon: Users,
    },
  ];

  const handleSaveProfile = () => {
    setIsEditing(false);
  };

  const generateServiceCode = () => rewardsSummary?.referralCode || "Loading…";

  const copyServiceCode = async () => {
    if (!rewardsSummary?.referralCode) return;
    await navigator.clipboard.writeText(rewardsSummary.referralCode);
    toast({ title: "Referral code copied" });
  };

  const shareReferralLink = async () => {
    if (!rewardsSummary?.referralCode) return;
    const url = `${window.location.origin}/register?ref=${encodeURIComponent(rewardsSummary.referralCode)}&loyaltyOrganization=${encodeURIComponent(rewardsSummary.organizationId)}`;
    if (navigator.share) {
      await navigator.share({ title: "Join me", text: "Use my referral code when you sign up.", url });
      return;
    }
    await navigator.clipboard.writeText(url);
    toast({ title: "Referral link copied" });
  };

  const updateRewardsEnrollment = async (enrolled: boolean) => {
    if (!selectedRewardsOrganization) return;
    const { error } = await supabase.rpc("set_my_hotel_loyalty_enrollment", {
      target_organization_id: selectedRewardsOrganization,
      target_enrolled: enrolled,
    });
    if (error) {
      toast({ title: "Rewards preference could not be saved", description: error.message, variant: "destructive" });
      return;
    }
    const { data: programs, error: refreshError } = await supabase.rpc("get_my_hotel_loyalty_programs");
    if (!refreshError) setRewardsPrograms((programs || []) as RewardsSummary[]);
    else setRewardsPrograms((current) => current.map((program) =>
      program.organizationId === selectedRewardsOrganization ? { ...program, enrolled } : program,
    ));
    toast({ title: enrolled ? "Rewards enrollment enabled" : "Rewards enrollment paused" });
  };

  return (
    <div className="min-h-screen bg-gradient-to-b from-sheraton-cream to-background">
      <div className="container py-8">
        {/* Header */}
        <div className="text-center mb-8">
          <div className="flex items-center justify-center mb-4">
            <Briefcase className="h-8 w-8 text-sheraton-gold mr-2" />
            <Badge className="bg-sheraton-gold text-sheraton-navy px-4 py-2">
              {userRole === 'manager' ? 'Property Manager' : userRole === 'guest' ? 'Guest Member' : 'Service Partner'}
            </Badge>
          </div>
          {userData.firstName && (
            <h1 className="text-4xl md:text-5xl font-bold text-sheraton-navy mb-4">
              {userRole === 'manager'
                ? `Good to see you, ${userData.firstName}!`
                : `Welcome back, ${userData.firstName}!`
              }
            </h1>
          )}
          <p className="text-lg text-muted-foreground">
            {userRole === 'manager'
              ? 'Manage your properties and service team • Dashboard'
              : userRole === 'guest'
                ? 'Your guest profile and rewards'
                : 'Your service profile and rewards'
            }
          </p>
        </div>

        <Tabs
          value={activeTab}
          onValueChange={setActiveTab}
          className="space-y-8"
        >
          <TabsList className="grid w-full grid-cols-2 lg:grid-cols-8 h-auto p-1">
            <TabsTrigger
              value="dashboard"
              className="flex items-center gap-2 py-3"
            >
              <Briefcase className="h-4 w-4" />
              <span className="hidden sm:inline">Dashboard</span>
            </TabsTrigger>
            <TabsTrigger
              value="performance"
              className="flex items-center gap-2 py-3"
            >
              <BarChart3 className="h-4 w-4" />
              <span className="hidden sm:inline">{userRole === 'manager' ? 'Analytics' : 'Performance'}</span>
            </TabsTrigger>
            <TabsTrigger
              value="profile"
              className="flex items-center gap-2 py-3"
            >
              <User className="h-4 w-4" />
              <span className="hidden sm:inline">Profile</span>
            </TabsTrigger>
            <TabsTrigger
              value="activities"
              className="flex items-center gap-2 py-3"
            >
              <Receipt className="h-4 w-4" />
              <span className="hidden sm:inline">{userRole === 'manager' ? 'Reports' : 'Activities'}</span>
            </TabsTrigger>
            <TabsTrigger
              value="billing"
              className="flex items-center gap-2 py-3"
            >
              <CreditCard className="h-4 w-4" />
              <span className="hidden sm:inline">Billing</span>
            </TabsTrigger>
            <TabsTrigger
              value="preferences"
              className="flex items-center gap-2 py-3"
            >
              <Settings className="h-4 w-4" />
              <span className="hidden sm:inline">Preferences</span>
            </TabsTrigger>
            <TabsTrigger value="rewards" className="flex items-center gap-2 py-3">
              <Gift className="h-4 w-4" />
              <span className="hidden sm:inline">Rewards</span>
            </TabsTrigger>
            <TabsTrigger
              value="referrals"
              className="flex items-center gap-2 py-3"
            >
              <Share2 className="h-4 w-4" />
              <span className="hidden sm:inline">Refer</span>
            </TabsTrigger>
          </TabsList>

          {/* Dashboard Tab */}
          <TabsContent value="dashboard" className="space-y-6">
            {userRole === 'manager' ? (
              // Manager Dashboard
              <>
                <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
                  {/* Manager Profile Card */}
                  <Card className="lg:col-span-1">
                    <CardHeader className="text-center">
                      <div className="relative w-24 h-24 mx-auto mb-4">
                        <Avatar className="w-24 h-24">
                          <AvatarImage src={userData.profilePicture} />
                          <AvatarFallback className="text-2xl font-bold bg-sheraton-gold text-sheraton-navy">
                            {userData.firstName[0]}
                            {userData.lastName[0]}
                          </AvatarFallback>
                        </Avatar>
                        <Button
                          size="sm"
                          className="absolute -bottom-2 -right-2 rounded-full w-8 h-8 p-0 sheraton-gradient"
                        >
                          <Camera className="h-4 w-4" />
                        </Button>
                      </div>
                      <CardTitle className="text-sheraton-navy">
                        {userData.firstName} {userData.lastName}
                      </CardTitle>
                      <Badge className="sheraton-gradient text-white">
                        Property Manager
                      </Badge>
                    </CardHeader>
                    <CardContent className="space-y-4">
                      <div className="text-center">
                        <div className="text-2xl font-bold text-sheraton-gold mb-1">
                          {format(new Date(userData.memberSince), "MMM yyyy")}
                        </div>
                        <div className="text-sm text-muted-foreground">
                          Manager Since
                        </div>
                      </div>

                      <Separator />

                      <div className="grid grid-cols-2 gap-4 text-center">
                        <div>
                          <div className="text-lg font-semibold">5</div>
                          <div className="text-xs text-muted-foreground">
                            Properties
                          </div>
                        </div>
                        <div>
                          <div className="text-lg font-semibold">23</div>
                          <div className="text-xs text-muted-foreground">
                            Active Tasks
                          </div>
                        </div>
                      </div>
                    </CardContent>
                  </Card>

                  {/* Manager Overview */}
                  <Card className="lg:col-span-2">
                    <CardHeader>
                      <CardTitle className="flex items-center gap-2">
                        <Zap className="h-5 w-5 text-sheraton-gold" />
                        Management Overview
                      </CardTitle>
                    </CardHeader>
                    <CardContent className="space-y-6">
                      {/* Key Metrics */}
                      <div className="grid grid-cols-3 gap-4">
                        <div className="text-center p-3 bg-blue-50 rounded-lg">
                          <div className="text-lg font-semibold text-blue-700">
                            12
                          </div>
                          <div className="text-xs text-blue-600">Pending Tasks</div>
                        </div>
                        <div className="text-center p-3 bg-green-50 rounded-lg">
                          <div className="text-lg font-semibold text-green-700">
                            8
                          </div>
                          <div className="text-xs text-green-600">In Progress</div>
                        </div>
                        <div className="text-center p-3 bg-purple-50 rounded-lg">
                          <div className="text-lg font-semibold text-purple-700">
                            3
                          </div>
                          <div className="text-xs text-purple-600">Completed Today</div>
                        </div>
                      </div>

                      {/* Quick Actions */}
                      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
                        <Link to="/tasks/list">
                          <Button className="w-full h-20 flex flex-col gap-2 sheraton-gradient text-white">
                            <CheckCircle className="h-6 w-6" />
                            <span className="text-xs">All Tasks</span>
                          </Button>
                        </Link>
                        <Link to="/reports">
                          <Button
                            className="w-full h-20 flex flex-col gap-2"
                            variant="outline"
                          >
                            <BarChart3 className="h-6 w-6 text-sheraton-gold" />
                            <span className="text-xs">Reports</span>
                          </Button>
                        </Link>
                        <Link to="/accounts">
                          <Button
                            className="w-full h-20 flex flex-col gap-2"
                            variant="outline"
                          >
                            <Users className="h-6 w-6 text-sheraton-gold" />
                            <span className="text-xs">Team</span>
                          </Button>
                        </Link>
                        <Link to="/profile">
                          <Button
                            className="w-full h-20 flex flex-col gap-2"
                            variant="outline"
                          >
                            <Settings className="h-6 w-6 text-sheraton-gold" />
                            <span className="text-xs">Settings</span>
                          </Button>
                        </Link>
                      </div>

                      {/* Budget Overview */}
                      <div className="space-y-3">
                        <h3 className="font-semibold text-sheraton-navy">
                          Budget Status
                        </h3>
                        <div className="p-3 bg-amber-50 rounded-lg border border-amber-200">
                          <div className="flex justify-between text-sm mb-2">
                            <span>Monthly Budget</span>
                            <span className="font-semibold">$8,500 / $10,000</span>
                          </div>
                          <Progress value={85} className="h-2" />
                        </div>
                      </div>
                    </CardContent>
                  </Card>
                </div>

                {/* Recent Tasks */}
                <Card>
                  <CardHeader>
                    <CardTitle className="flex items-center gap-2">
                      <History className="h-5 w-5 text-sheraton-gold" />
                      Recent Tasks
                    </CardTitle>
                  </CardHeader>
                  <CardContent>
                    <div className="space-y-3">
                      {recentActivities.slice(0, 3).map((activity) => (
                        <div
                          key={activity.id}
                          className="flex items-center justify-between"
                        >
                          <div className="flex items-center gap-3">
                            <div
                              className={`w-10 h-10 rounded-full flex items-center justify-center ${
                                activity.type === "completion"
                                  ? "bg-green-100 text-green-600"
                                  : "bg-blue-100 text-blue-600"
                              }`}
                            >
                              {activity.type === "completion" ? (
                                <CheckCircle className="h-5 w-5" />
                              ) : (
                                <Clock className="h-5 w-5" />
                              )}
                            </div>
                            <div>
                              <h4 className="font-medium">
                                {activity.description}
                              </h4>
                              <p className="text-sm text-muted-foreground">
                                {format(new Date(activity.date), "MMM dd, yyyy")}
                              </p>
                            </div>
                          </div>
                          <Badge
                            className={
                              activity.type === "completion"
                                ? "bg-green-100 text-green-700"
                                : "bg-blue-100 text-blue-700"
                            }
                          >
                            {activity.status}
                          </Badge>
                        </div>
                      ))}
                    </div>
                    <Button variant="outline" className="w-full mt-4">
                      View All Tasks
                    </Button>
                  </CardContent>
                </Card>
              </>
            ) : (
              // Service Provider Dashboard
              <>
                <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
                  {/* Service Summary */}
                  <Card className="lg:col-span-1">
                    <CardHeader className="text-center">
                      <div className="relative w-24 h-24 mx-auto mb-4">
                        <Avatar className="w-24 h-24">
                          <AvatarImage src={userData.profilePicture} />
                          <AvatarFallback className="text-2xl font-bold bg-sheraton-gold text-sheraton-navy">
                            {userData.firstName[0]}
                            {userData.lastName[0]}
                          </AvatarFallback>
                        </Avatar>
                        <Button
                          size="sm"
                          className="absolute -bottom-2 -right-2 rounded-full w-8 h-8 p-0 sheraton-gradient"
                        >
                          <Camera className="h-4 w-4" />
                        </Button>
                      </div>
                      <CardTitle className="text-sheraton-navy">
                        {userData.firstName} {userData.lastName}
                      </CardTitle>
                      <Badge className="sheraton-gradient text-white">
                        {performanceData.performanceTier}
                      </Badge>
                    </CardHeader>
                    <CardContent className="space-y-4">
                      <div className="text-center">
                        <div className="text-2xl font-bold text-sheraton-gold mb-1">
                          {performanceData.currentRating}
                        </div>
                        <div className="text-sm text-muted-foreground">
                          Service Rating
                        </div>
                      </div>

                      <div className="space-y-2">
                        <div className="flex justify-between text-sm">
                          <span>Progress to {performanceData.nextBadge}</span>
                          <span>{performanceData.badgeProgress}%</span>
                        </div>
                        <Progress
                          value={performanceData.badgeProgress}
                          className="h-2"
                        />
                        <div className="text-xs text-muted-foreground text-center">
                          {performanceData.pointsToNextBadge} points to next tier
                        </div>
                      </div>

                      <div className="grid grid-cols-2 gap-4 text-center">
                        <div>
                          <div className="text-lg font-semibold">
                            {format(new Date(userData.memberSince), "MMM yyyy")}
                          </div>
                          <div className="text-xs text-muted-foreground">
                            Partner Since
                          </div>
                        </div>
                        <div>
                          <div className="text-lg font-semibold">
                            {performanceData.lifetimeTasks}
                          </div>
                          <div className="text-xs text-muted-foreground">
                            Tasks Completed
                          </div>
                        </div>
                      </div>
                    </CardContent>
                  </Card>

                  {/* Quick Stats & Opportunities */}
                  <Card className="lg:col-span-2">
                    <CardHeader>
                      <CardTitle className="flex items-center gap-2">
                        <Zap className="h-5 w-5 text-sheraton-gold" />
                        Performance Overview
                      </CardTitle>
                    </CardHeader>
                    <CardContent className="space-y-6">
                      {/* Key Metrics */}
                      <div className="grid grid-cols-3 gap-4">
                        <div className="text-center p-3 bg-blue-50 rounded-lg">
                          <div className="text-lg font-semibold text-blue-700">
                            {performanceData.tasksInProgress}
                          </div>
                          <div className="text-xs text-blue-600">In Progress</div>
                        </div>
                        <div className="text-center p-3 bg-green-50 rounded-lg">
                          <div className="text-lg font-semibold text-green-700">
                            {performanceData.qualityScore}%
                          </div>
                          <div className="text-xs text-green-600">Quality Score</div>
                        </div>
                        <div className="text-center p-3 bg-purple-50 rounded-lg">
                          <div className="text-lg font-semibold text-purple-700">
                            {performanceData.avgCompletionTime}
                          </div>
                          <div className="text-xs text-purple-600">Avg. Time</div>
                        </div>
                      </div>

                      {/* Quick Actions */}
                      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
                        <Link to="/tasks/list">
                          <Button className="w-full h-20 flex flex-col gap-2 sheraton-gradient text-white">
                            <CheckCircle className="h-6 w-6" />
                            <span className="text-xs">View Tasks</span>
                          </Button>
                        </Link>
                        <Link to="/reports">
                          <Button
                            className="w-full h-20 flex flex-col gap-2"
                            variant="outline"
                          >
                            <BarChart3 className="h-6 w-6 text-sheraton-gold" />
                            <span className="text-xs">Reports</span>
                          </Button>
                        </Link>
                        <Link to="/accounts">
                          <Button
                            className="w-full h-20 flex flex-col gap-2"
                            variant="outline"
                          >
                            <Users className="h-6 w-6 text-sheraton-gold" />
                            <span className="text-xs">Team</span>
                          </Button>
                        </Link>
                        <Link to="/profile">
                          <Button
                            className="w-full h-20 flex flex-col gap-2"
                            variant="outline"
                          >
                            <Settings className="h-6 w-6 text-sheraton-gold" />
                            <span className="text-xs">Settings</span>
                          </Button>
                        </Link>
                      </div>

                      {/* Active Opportunities */}
                      <div className="space-y-3">
                        <h3 className="font-semibold text-sheraton-navy">
                          Active Opportunities
                        </h3>
                        {activeOpportunities.slice(0, 2).map((opportunity) => (
                          <div
                            key={opportunity.id}
                            className="flex items-center justify-between p-3 bg-sheraton-gold/10 rounded-lg border border-sheraton-gold/30"
                          >
                            <div className="flex items-center gap-3">
                              <div className="text-2xl">{opportunity.emoji}</div>
                              <div>
                                <h4 className="font-medium text-sheraton-navy">
                                  {opportunity.title}
                                </h4>
                                <p className="text-sm text-muted-foreground">
                                  {opportunity.description}
                                </p>
                              </div>
                            </div>
                            <Button
                              size="sm"
                              className="sheraton-gradient text-white"
                            >
                              View
                            </Button>
                          </div>
                        ))}
                      </div>
                    </CardContent>
                  </Card>
                </div>

                {/* Recent Activities */}
                <Card>
                  <CardHeader>
                    <CardTitle className="flex items-center gap-2">
                      <History className="h-5 w-5 text-sheraton-gold" />
                      Recent Activities
                    </CardTitle>
                  </CardHeader>
                  <CardContent>
                    <div className="space-y-3">
                      {recentActivities.slice(0, 3).map((activity) => (
                        <div
                          key={activity.id}
                          className="flex items-center justify-between"
                        >
                          <div className="flex items-center gap-3">
                            <div
                              className={`w-10 h-10 rounded-full flex items-center justify-center ${
                                activity.type === "completion"
                                  ? "bg-green-100 text-green-600"
                                  : "bg-blue-100 text-blue-600"
                              }`}
                            >
                              {activity.type === "completion" ? (
                                <CheckCircle className="h-5 w-5" />
                              ) : (
                                <Gift className="h-5 w-5" />
                              )}
                            </div>
                            <div>
                              <h4 className="font-medium">
                                {activity.description}
                              </h4>
                              <p className="text-sm text-muted-foreground">
                                {format(new Date(activity.date), "MMM dd, yyyy")}
                              </p>
                            </div>
                          </div>
                          <div
                            className={`font-semibold ${
                              activity.type === "completion"
                                ? "text-green-600"
                                : "text-blue-600"
                            }`}
                          >
                            {activity.points}
                          </div>
                        </div>
                      ))}
                    </div>
                    <Button variant="outline" className="w-full mt-4">
                      View All Activities
                    </Button>
                  </CardContent>
                </Card>
              </>
            )}
          </TabsContent>

          {/* Performance Tab */}
          <TabsContent value="performance" className="space-y-6">
            {userRole === 'manager' ? (
              // Manager Analytics
              <>
                <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
                  {/* Overall Portfolio Health */}
                  <Card className="sheraton-gradient text-white">
                    <CardHeader>
                      <CardTitle className="flex items-center gap-2">
                        <BarChart3 className="h-5 w-5" />
                        Portfolio Health
                      </CardTitle>
                    </CardHeader>
                    <CardContent className="space-y-4">
                      <div className="text-center">
                        <div className="text-4xl font-bold mb-2">94%</div>
                        <div className="text-white/80">Overall Efficiency</div>
                      </div>

                      <div className="grid grid-cols-3 gap-4 text-center">
                        <div>
                          <div className="text-lg font-semibold">23</div>
                          <div className="text-xs text-white/70">Active Tasks</div>
                        </div>
                        <div>
                          <div className="text-lg font-semibold">145</div>
                          <div className="text-xs text-white/70">Total Completed</div>
                        </div>
                        <div>
                          <div className="text-lg font-semibold">3.2d</div>
                          <div className="text-xs text-white/70">Avg Turnaround</div>
                        </div>
                      </div>

                      <div className="grid grid-cols-2 gap-2">
                        <Button className="bg-white text-sheraton-navy hover:bg-white/90">
                          <BarChart3 className="h-4 w-4 mr-2" />
                          Full Analytics
                        </Button>
                        <Button
                          variant="outline"
                          className="border-white text-white hover:bg-white/10"
                        >
                          <Download className="h-4 w-4 mr-2" />
                          Export
                        </Button>
                      </div>
                    </CardContent>
                  </Card>

                  {/* Service Provider Performance */}
                  <Card>
                    <CardHeader>
                      <CardTitle className="flex items-center gap-2">
                        <Users className="h-5 w-5 text-sheraton-gold" />
                        Service Team Performance
                      </CardTitle>
                    </CardHeader>
                    <CardContent className="space-y-4">
                      <div className="space-y-3">
                        {[
                          { name: 'John Smith', rating: 4.8, tasks: 42 },
                          { name: 'Sarah Johnson', rating: 4.6, tasks: 38 },
                          { name: 'Mike Brown', rating: 4.9, tasks: 45 },
                        ].map((provider, index) => (
                          <div key={index} className="p-3 border rounded-lg">
                            <div className="flex justify-between items-center mb-2">
                              <h4 className="font-medium text-sm">{provider.name}</h4>
                              <Badge variant="outline">{provider.rating} ⭐</Badge>
                            </div>
                            <div className="flex items-center justify-between text-xs text-muted-foreground">
                              <span>{provider.tasks} tasks completed</span>
                              <span>Top Performer</span>
                            </div>
                          </div>
                        ))}
                      </div>

                      <Separator />

                      <Button variant="outline" className="w-full">
                        View All Providers
                      </Button>
                    </CardContent>
                  </Card>
                </div>

                {/* Key Metrics */}
                <Card>
                  <CardHeader>
                    <CardTitle className="flex items-center gap-2">
                      <TrendingUp className="h-5 w-5 text-sheraton-gold" />
                      Property Management Metrics
                    </CardTitle>
                  </CardHeader>
                  <CardContent>
                    <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
                      <div className="text-center p-4 border rounded-lg">
                        <DollarSign className="h-8 w-8 mx-auto mb-2 text-sheraton-gold" />
                        <h3 className="font-medium text-sm mb-1">Budget Utilization</h3>
                        <p className="text-lg font-semibold">85%</p>
                      </div>
                      <div className="text-center p-4 border rounded-lg">
                        <Clock className="h-8 w-8 mx-auto mb-2 text-sheraton-gold" />
                        <h3 className="font-medium text-sm mb-1">On-Time Rate</h3>
                        <p className="text-lg font-semibold">96%</p>
                      </div>
                      <div className="text-center p-4 border rounded-lg">
                        <Star className="h-8 w-8 mx-auto mb-2 text-sheraton-gold" />
                        <h3 className="font-medium text-sm mb-1">Avg Rating</h3>
                        <p className="text-lg font-semibold">4.7/5</p>
                      </div>
                      <div className="text-center p-4 border rounded-lg">
                        <CheckCircle className="h-8 w-8 mx-auto mb-2 text-sheraton-gold" />
                        <h3 className="font-medium text-sm mb-1">Completion Rate</h3>
                        <p className="text-lg font-semibold">98%</p>
                      </div>
                    </div>
                  </CardContent>
                </Card>
              </>
            ) : (
              // Service Provider Performance
              <>
                <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
                  {/* Performance Metrics */}
                  <Card className="sheraton-gradient text-white">
                    <CardHeader>
                      <CardTitle className="flex items-center gap-2">
                        <Star className="h-5 w-5" />
                        Your Performance
                      </CardTitle>
                    </CardHeader>
                    <CardContent className="space-y-4">
                      <div className="text-center">
                        <div className="text-4xl font-bold mb-2">
                          {performanceData.currentRating}
                        </div>
                        <div className="text-white/80">Service Rating</div>
                      </div>

                      <div className="grid grid-cols-3 gap-4 text-center">
                        <div>
                          <div className="text-lg font-semibold">
                            {performanceData.tasksCompleted}
                          </div>
                          <div className="text-xs text-white/70">Completed</div>
                        </div>
                        <div>
                          <div className="text-lg font-semibold">
                            {performanceData.qualityScore}%
                          </div>
                          <div className="text-xs text-white/70">Quality</div>
                        </div>
                        <div>
                          <div className="text-lg font-semibold">
                            {performanceData.tasksInProgress}
                          </div>
                          <div className="text-xs text-white/70">In Progress</div>
                        </div>
                      </div>

                      <div className="grid grid-cols-2 gap-2">
                        <Button className="bg-white text-sheraton-navy hover:bg-white/90">
                          <BarChart3 className="h-4 w-4 mr-2" />
                          Analytics
                        </Button>
                        <Button
                          variant="outline"
                          className="border-white text-white hover:bg-white/10"
                        >
                          <Download className="h-4 w-4 mr-2" />
                          Report
                        </Button>
                      </div>
                    </CardContent>
                  </Card>

                  {/* Tier Benefits */}
                  <Card>
                    <CardHeader>
                      <CardTitle className="flex items-center gap-2">
                        <Award className="h-5 w-5 text-sheraton-gold" />
                        {performanceData.performanceTier} Benefits
                      </CardTitle>
                    </CardHeader>
                    <CardContent className="space-y-4">
                      <div className="space-y-2">
                        {performanceData.benefits.map((benefit, index) => (
                          <div key={index} className="flex items-center gap-2">
                            <CheckCircle className="h-4 w-4 text-green-500" />
                            <span className="text-sm">{benefit}</span>
                          </div>
                        ))}
                      </div>

                      <Separator />

                      <div>
                        <h4 className="font-medium mb-2 text-sheraton-navy">
                          Unlock {performanceData.nextBadge}
                        </h4>
                        <div className="space-y-1">
                          {performanceData.nextTierBenefits
                            .slice(0, 3)
                            .map((benefit, index) => (
                              <div key={index} className="flex items-center gap-2">
                                <Target className="h-4 w-4 text-sheraton-gold" />
                                <span className="text-sm text-muted-foreground">
                                  {benefit}
                                </span>
                              </div>
                            ))}
                        </div>
                      </div>
                    </CardContent>
                  </Card>
                </div>

                {/* How to Improve Performance */}
                <Card>
                  <CardHeader>
                    <CardTitle className="flex items-center gap-2">
                      <TrendingUp className="h-5 w-5 text-sheraton-gold" />
                      Ways to Earn Recognition Points
                    </CardTitle>
                  </CardHeader>
                  <CardContent>
                    <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
                      {taskEarningActivities.map((activity, index) => (
                        <div
                          key={index}
                          className="text-center p-4 border rounded-lg"
                        >
                          <activity.icon className="h-8 w-8 mx-auto mb-2 text-sheraton-gold" />
                          <h3 className="font-medium mb-1">{activity.activity}</h3>
                          <p className="text-sm text-muted-foreground">
                            {activity.points}
                          </p>
                        </div>
                      ))}
                    </div>
                  </CardContent>
                </Card>
              </>
            )}
          </TabsContent>

          {/* Profile Tab */}
          <TabsContent value="profile" className="space-y-6">
            <Card>
              <CardHeader className="flex flex-row items-center justify-between">
                <CardTitle>Personal Information</CardTitle>
                <Button
                  onClick={() =>
                    isEditing ? handleSaveProfile() : setIsEditing(true)
                  }
                  className={isEditing ? "sheraton-gradient text-white" : ""}
                >
                  {isEditing ? (
                    <>
                      <CheckCircle className="h-4 w-4 mr-2" />
                      Save Changes
                    </>
                  ) : (
                    <>
                      <Edit className="h-4 w-4 mr-2" />
                      Edit Profile
                    </>
                  )}
                </Button>
              </CardHeader>
              <CardContent className="space-y-6">
                <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                  {userRole === 'manager' && (
                    <>
                      <div className="space-y-2 md:col-span-2">
                        <Label htmlFor="organizationName">Hotel / Organization Name *</Label>
                        <Input
                          id="organizationName"
                          value={userData.organizationName}
                          onChange={(e) => {
                            setUserData({ ...userData, organizationName: e.target.value });
                            saveFieldToDatabase("organizationName", e.target.value);
                          }}
                          disabled={!isEditing}
                        />
                      </div>
                      <div className="space-y-2 md:col-span-2">
                        <Label htmlFor="hotelStarRating">Official hotel star classification</Label>
                        <Select
                          value={userData.hotelStarRating || "unclassified"}
                          onValueChange={(value) => {
                            const rating = value === "unclassified" ? "" : value;
                            setUserData({ ...userData, hotelStarRating: rating });
                            saveFieldToDatabase("hotelStarRating", rating || null);
                          }}
                          disabled={!isEditing}
                        >
                          <SelectTrigger id="hotelStarRating"><SelectValue placeholder="Select classification" /></SelectTrigger>
                          <SelectContent>
                            <SelectItem value="unclassified">Not classified</SelectItem>
                            {[1, 2, 3, 4, 5].map((rating) => (
                              <SelectItem key={rating} value={String(rating)}>{rating}-star hotel</SelectItem>
                            ))}
                          </SelectContent>
                        </Select>
                        <p className="text-xs text-muted-foreground">This classification determines the Local Hotel Tax charged on guest room bookings.</p>
                      </div>
                    </>
                  )}
                  <div className="space-y-2">
                    <Label htmlFor="firstName">First Name *</Label>
                    <Input
                      id="firstName"
                      value={userData.firstName}
                      onChange={(e) => {
                        setUserData({ ...userData, firstName: e.target.value });
                        saveFieldToDatabase("firstName", e.target.value);
                      }}
                      disabled={!isEditing}
                    />
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="lastName">Last Name *</Label>
                    <Input
                      id="lastName"
                      value={userData.lastName}
                      onChange={(e) => {
                        setUserData({ ...userData, lastName: e.target.value });
                        saveFieldToDatabase("lastName", e.target.value);
                      }}
                      disabled={!isEditing}
                    />
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="email">Email Address *</Label>
                    <Input
                      id="email"
                      type="email"
                      value={userData.email}
                      onChange={(e) => {
                        setUserData({ ...userData, email: e.target.value });
                        saveFieldToDatabase("email", e.target.value);
                      }}
                      disabled={!isEditing}
                    />
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="phone">Phone Number</Label>
                    <Input
                      id="phone"
                      value={userData.phone}
                      onChange={(e) => {
                        setUserData({ ...userData, phone: e.target.value });
                        saveFieldToDatabase("phone", e.target.value);
                      }}
                      disabled={!isEditing}
                    />
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="birthday">Birthday</Label>
                    <Input
                      id="birthday"
                      type="date"
                      value={userData.birthday}
                      onChange={(e) => {
                        setUserData({ ...userData, birthday: e.target.value });
                        saveFieldToDatabase("birthday", e.target.value);
                      }}
                      disabled={!isEditing}
                    />
                  </div>
                  <div className="space-y-2">
                    <Label htmlFor="location">Location</Label>
                    <Input
                      id="location"
                      value={userData.location}
                      onChange={(e) => {
                        setUserData({ ...userData, location: e.target.value });
                        saveFieldToDatabase("location", e.target.value);
                      }}
                      disabled={!isEditing}
                    />
                  </div>
                </div>
              </CardContent>
            </Card>
          </TabsContent>

          {/* Activities Tab */}
          <TabsContent value="activities" className="space-y-6">
            {userRole === 'manager' ? (
              // Manager Reports
              <>
                <Card>
                  <CardHeader>
                    <CardTitle className="flex items-center gap-2">
                      <BarChart3 className="h-5 w-5 text-sheraton-gold" />
                      Management Reports
                    </CardTitle>
                  </CardHeader>
                  <CardContent>
                    <div className="space-y-4">
                      {[
                        {
                          title: 'Monthly Task Report',
                          date: '2024-01-15',
                          tasks: 23,
                          completed: 21,
                          status: 'completed',
                        },
                        {
                          title: 'Budget Utilization Report',
                          date: '2024-01-14',
                          budget: '$8,500/$10,000',
                          status: 'completed',
                        },
                        {
                          title: 'Service Provider Performance Review',
                          date: '2024-01-10',
                          providers: 5,
                          avgRating: 4.7,
                          status: 'completed',
                        },
                        {
                          title: 'Property Maintenance Summary',
                          date: '2024-01-08',
                          properties: 5,
                          activeIssues: 2,
                          status: 'completed',
                        },
                      ].map((report, index) => (
                        <div
                          key={index}
                          className="flex items-center justify-between p-4 border rounded-lg"
                        >
                          <div className="flex items-center gap-4">
                            <div className="w-12 h-12 rounded-full flex items-center justify-center bg-blue-100 text-blue-600">
                              <BarChart3 className="h-6 w-6" />
                            </div>
                            <div>
                              <h4 className="font-medium">{report.title}</h4>
                              <p className="text-sm text-muted-foreground">
                                {format(new Date(report.date), "MMM dd, yyyy")}
                              </p>
                            </div>
                          </div>
                          <div className="flex items-center gap-3">
                            <Badge className="bg-green-100 text-green-700">
                              {report.status}
                            </Badge>
                            <Button size="sm" variant="outline">
                              <Download className="h-4 w-4 mr-2" />
                              Export
                            </Button>
                          </div>
                        </div>
                      ))}
                    </div>
                  </CardContent>
                </Card>

                <Card>
                  <CardHeader>
                    <CardTitle className="flex items-center gap-2">
                      <History className="h-5 w-5 text-sheraton-gold" />
                      Recent Activity Log
                    </CardTitle>
                  </CardHeader>
                  <CardContent>
                    <div className="space-y-3">
                      {recentActivities.map((activity) => (
                        <div
                          key={activity.id}
                          className="flex items-center justify-between text-sm p-3 bg-muted rounded"
                        >
                          <div>
                            <p className="font-medium">{activity.description}</p>
                            <p className="text-xs text-muted-foreground">
                              {format(new Date(activity.date), "MMM dd, yyyy")}
                            </p>
                          </div>
                          <Badge variant="outline">{activity.status}</Badge>
                        </div>
                      ))}
                    </div>
                  </CardContent>
                </Card>
              </>
            ) : (
              // Service Provider Activities
              <Card>
                <CardHeader>
                  <CardTitle className="flex items-center gap-2">
                    <Receipt className="h-5 w-5 text-sheraton-gold" />
                    Activity History & Earnings
                  </CardTitle>
                </CardHeader>
                <CardContent>
                  <div className="space-y-4">
                    {recentActivities.map((activity) => (
                      <div
                        key={activity.id}
                        className="flex items-center justify-between p-4 border rounded-lg"
                      >
                        <div className="flex items-center gap-4">
                          <div
                            className={`w-12 h-12 rounded-full flex items-center justify-center ${
                              activity.type === "completion"
                                ? "bg-green-100 text-green-600"
                                : "bg-blue-100 text-blue-600"
                            }`}
                          >
                            {activity.type === "completion" ? (
                              <CheckCircle className="h-6 w-6" />
                            ) : (
                              <Gift className="h-6 w-6" />
                            )}
                          </div>
                          <div>
                            <h4 className="font-medium">
                              {activity.description}
                            </h4>
                            <p className="text-sm text-muted-foreground">
                              {format(new Date(activity.date), "MMM dd, yyyy")}{" "}
                              • {activity.status}
                            </p>
                          </div>
                        </div>
                        <div className="flex items-center gap-3">
                          <div
                            className={`font-semibold ${
                              activity.type === "completion"
                                ? "text-green-600"
                                : "text-blue-600"
                            }`}
                          >
                            {activity.points}
                          </div>
                          <Button size="sm" variant="outline">
                            <Download className="h-4 w-4 mr-2" />
                            Details
                          </Button>
                        </div>
                      </div>
                    ))}
                  </div>
                </CardContent>
              </Card>
            )}
          </TabsContent>

          {/* Billing Tab */}
          <TabsContent value="billing" className="space-y-6">
            <BillingTab userRole={userRole === "guest" ? null : userRole} userData={userData} />
          </TabsContent>

          {/* Preferences Tab */}
          <TabsContent value="preferences" className="space-y-6">
            <Card>
              <CardHeader>
                <CardTitle className="flex items-center gap-2">
                  <Heart className="h-5 w-5 text-sheraton-gold" />
                  Your Preferences
                </CardTitle>
              </CardHeader>
              <CardContent className="space-y-6">
                {userRole === 'manager' ? (
                  // Manager Preferences
                  <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                    <div className="space-y-4">
                      <h3 className="font-semibold">Management Preferences</h3>
                      <div className="space-y-3">
                        <div className="space-y-2">
                          <Label>Primary Property Type</Label>
                          <Select defaultValue="residential">
                            <SelectTrigger>
                              <SelectValue />
                            </SelectTrigger>
                            <SelectContent>
                              <SelectItem value="residential">
                                Residential
                              </SelectItem>
                              <SelectItem value="commercial">
                                Commercial
                              </SelectItem>
                              <SelectItem value="mixed">Mixed Use</SelectItem>
                            </SelectContent>
                          </Select>
                        </div>
                        <div className="space-y-2">
                          <Label>Preferred Reporting Frequency</Label>
                          <Select defaultValue="weekly">
                            <SelectTrigger>
                              <SelectValue />
                            </SelectTrigger>
                            <SelectContent>
                              <SelectItem value="daily">Daily</SelectItem>
                              <SelectItem value="weekly">Weekly</SelectItem>
                              <SelectItem value="monthly">Monthly</SelectItem>
                            </SelectContent>
                          </Select>
                        </div>
                        <div className="space-y-2">
                          <Label>Task Assignment Preference</Label>
                          <Select defaultValue="auto">
                            <SelectTrigger>
                              <SelectValue />
                            </SelectTrigger>
                            <SelectContent>
                              <SelectItem value="auto">
                                Automatic Assignment
                              </SelectItem>
                              <SelectItem value="manual">
                                Manual Assignment
                              </SelectItem>
                              <SelectItem value="approval">
                                Requires Approval
                              </SelectItem>
                            </SelectContent>
                          </Select>
                        </div>
                      </div>
                    </div>

                    <div className="space-y-4">
                      <h3 className="font-semibold">Notification Settings</h3>
                      <div className="space-y-3">
                        <div className="flex items-center justify-between">
                          <Label htmlFor="tasks">Task Alerts</Label>
                          <Switch
                            id="tasks"
                            checked={userData.preferences.notifications.tasks}
                          />
                        </div>
                        <div className="flex items-center justify-between">
                          <Label htmlFor="reports">Report Summaries</Label>
                          <Switch
                            id="reports"
                            checked={userData.preferences.notifications.reports}
                          />
                        </div>
                        <div className="flex items-center justify-between">
                          <Label htmlFor="alerts">Budget Warnings</Label>
                          <Switch
                            id="alerts"
                            checked={userData.preferences.notifications.alerts}
                          />
                        </div>
                        <div className="flex items-center justify-between">
                          <Label htmlFor="newsletter">Provider Updates</Label>
                          <Switch
                            id="newsletter"
                            checked={
                              userData.preferences.notifications.newsletter
                            }
                          />
                        </div>
                      </div>
                    </div>
                  </div>
                ) : (
                  // Service Provider Preferences
                  <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                    <div className="space-y-4">
                      <h3 className="font-semibold">Service Preferences</h3>
                      <div className="space-y-3">
                        <div className="space-y-2">
                          <Label>Preferred Task Categories</Label>
                          <Select value={userData.preferences.taskCategory}>
                            <SelectTrigger>
                              <SelectValue />
                            </SelectTrigger>
                            <SelectContent>
                              <SelectItem value="all">All Categories</SelectItem>
                              <SelectItem value="maintenance">
                                Maintenance
                              </SelectItem>
                              <SelectItem value="housekeeping">
                                Housekeeping
                              </SelectItem>
                            </SelectContent>
                          </Select>
                        </div>
                        <div className="space-y-2">
                          <Label>Notification Type</Label>
                          <Select value={userData.preferences.notificationType}>
                            <SelectTrigger>
                              <SelectValue />
                            </SelectTrigger>
                            <SelectContent>
                              <SelectItem value="detailed">Detailed</SelectItem>
                              <SelectItem value="summary">Summary</SelectItem>
                              <SelectItem value="minimal">Minimal</SelectItem>
                            </SelectContent>
                          </Select>
                        </div>
                        <div className="space-y-2">
                          <Label>Theme</Label>
                          <Select defaultValue="modern">
                            <SelectTrigger>
                              <SelectValue />
                            </SelectTrigger>
                            <SelectContent>
                              <SelectItem value="modern">Modern</SelectItem>
                              <SelectItem value="classic">Classic</SelectItem>
                              <SelectItem value="dark">Dark Mode</SelectItem>
                            </SelectContent>
                          </Select>
                        </div>
                      </div>
                    </div>

                    <div className="space-y-4">
                      <h3 className="font-semibold">Notification Settings</h3>
                      <div className="space-y-3">
                        <div className="flex items-center justify-between">
                          <Label htmlFor="tasks">Task Notifications</Label>
                          <Switch
                            id="tasks"
                            checked={userData.preferences.notifications.tasks}
                          />
                        </div>
                        <div className="flex items-center justify-between">
                          <Label htmlFor="reports">Report Updates</Label>
                          <Switch
                            id="reports"
                            checked={userData.preferences.notifications.reports}
                          />
                        </div>
                        <div className="flex items-center justify-between">
                          <Label htmlFor="alerts">System Alerts</Label>
                          <Switch
                            id="alerts"
                            checked={userData.preferences.notifications.alerts}
                          />
                        </div>
                        <div className="flex items-center justify-between">
                          <Label htmlFor="newsletter">Newsletter</Label>
                          <Switch
                            id="newsletter"
                            checked={
                              userData.preferences.notifications.newsletter
                            }
                          />
                        </div>
                      </div>
                    </div>
                  </div>
                )}
              </CardContent>
            </Card>
          </TabsContent>

          <TabsContent value="rewards" className="space-y-6">
            {rewardsLoadError && (
              <Card className="border-amber-300 bg-amber-50">
                <CardContent className="pt-6 text-sm text-amber-900">
                  Rewards data is not available yet. Apply the SQL steps in `supabase/loyalty-rewards-implementation.sql` to enable your account.
                </CardContent>
              </Card>
            )}
            {rewardsPrograms.length > 0 && (
              <div className="max-w-md space-y-2">
                <Label htmlFor="rewards-hotel">Hotel rewards account</Label>
                <Select value={selectedRewardsOrganization} onValueChange={setSelectedRewardsOrganization}>
                  <SelectTrigger id="rewards-hotel"><SelectValue placeholder="Choose a hotel" /></SelectTrigger>
                  <SelectContent>
                    {rewardsPrograms.map((program) => (
                      <SelectItem key={program.organizationId} value={program.organizationId}>
                        {program.organizationName} — {program.programName}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
            )}
            {!rewardsLoadError && rewardsPrograms.length === 0 && (
              <Card><CardContent className="pt-6 text-sm text-muted-foreground">
                No hotel rewards programs are available yet. Each hotel manages its own program and balance.
              </CardContent></Card>
            )}
            {rewardsSummary && !rewardsSummary.policy.programEnabled && (
              <Card className="border-amber-300 bg-amber-50"><CardContent className="pt-6 text-sm text-amber-900">
                This hotel rewards program is currently inactive.
              </CardContent></Card>
            )}
            {rewardsSummary && <Card>
              <CardContent className="flex flex-col gap-4 pt-6 sm:flex-row sm:items-center sm:justify-between">
                <div>
                  <h3 className="font-semibold text-sheraton-navy">Rewards enrollment</h3>
                  <p className="text-sm text-muted-foreground">{rewardsSummary?.enrolled ? "Eligible purchases and approved activity can earn points." : "Enrollment is paused. Your existing points and history are preserved."}</p>
                </div>
                <div className="flex items-center gap-3">
                  <Label htmlFor="rewards-enrollment">{rewardsSummary?.enrolled ? "Enrolled" : "Not enrolled"}</Label>
                  <Switch id="rewards-enrollment" checked={rewardsSummary?.enrolled ?? false} disabled={!rewardsSummary} onCheckedChange={updateRewardsEnrollment} />
                </div>
              </CardContent>
            </Card>}
            {rewardsSummary && <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
              <Card className="lg:col-span-2 sheraton-gradient text-white">
                <CardHeader>
                  <CardTitle className="flex items-center gap-2">
                    <Wallet className="h-5 w-5" /> Your Points Wallet
                  </CardTitle>
                </CardHeader>
                <CardContent className="space-y-5">
                  <div className="text-center">
                    <div className="text-4xl font-bold mb-2">
                      {(rewardsSummary?.availablePoints ?? 0).toLocaleString()}
                    </div>
                    <div className="text-white/80">Available points</div>
                  </div>
                  <div className="grid grid-cols-2 gap-4 text-center">
                    <div>
                      <div className="text-lg font-semibold">{(rewardsSummary?.lifetimePoints ?? 0).toLocaleString()}</div>
                      <div className="text-xs text-white/70">Lifetime earned</div>
                    </div>
                    <div>
                      <div className="text-lg font-semibold">{(rewardsSummary?.debtPoints ?? 0).toLocaleString()}</div>
                      <div className="text-xs text-white/70">Reversed points owed</div>
                    </div>
                  </div>
                  <div className="rounded-lg bg-white/15 p-3 text-sm">
                    Points are promotional rewards, not cash, stored value, or a withdrawable wallet balance.
                  </div>
                </CardContent>
              </Card>
              <Card>
                <CardHeader><CardTitle>Referral progress</CardTitle></CardHeader>
                <CardContent className="space-y-4">
                  <div className="text-center p-4 border rounded-lg">
                    <div className="text-3xl font-bold text-sheraton-gold">{rewardsSummary?.referrals.qualified ?? 0}</div>
                    <div className="text-sm text-muted-foreground">Qualified referrals</div>
                  </div>
                  <div className="text-center p-4 border rounded-lg">
                    <div className="text-2xl font-bold text-sheraton-gold">{(rewardsSummary?.referrals.pointsEarned ?? 0).toLocaleString()}</div>
                    <div className="text-sm text-muted-foreground">Referral points earned</div>
                  </div>
                  <p className="text-sm text-muted-foreground">{rewardsSummary?.referrals.pending ?? 0} referrals are waiting for a qualifying milestone.</p>
                </CardContent>
              </Card>
            </div>}
            {rewardsSummary && <Card>
              <CardHeader><CardTitle className="flex items-center gap-2"><History className="h-5 w-5 text-sheraton-gold" /> Rewards activity at {rewardsSummary.organizationName}</CardTitle></CardHeader>
              <CardContent>
                {recentActivities.length ? (
                  <div className="space-y-3">
                    {recentActivities.slice(0, 10).map((entry) => (
                      <div key={entry.id} className="flex items-center justify-between border-b last:border-0 pb-3 last:pb-0">
                        <div><p className="font-medium">{entry.description}</p><p className="text-sm text-muted-foreground">{format(new Date(entry.date), "MMM dd, yyyy")}</p></div>
                        <span className={`font-semibold ${entry.points.startsWith("-") ? "text-red-600" : "text-green-600"}`}>{entry.points}</span>
                      </div>
                    ))}
                  </div>
                ) : <p className="text-sm text-muted-foreground">No rewards activity yet.</p>}
              </CardContent>
            </Card>}
            {rewardsSummary && <Card>
              <CardHeader><CardTitle className="flex items-center gap-2"><TrendingUp className="h-5 w-5 text-sheraton-gold" /> How rewards are earned at {rewardsSummary.organizationName}</CardTitle></CardHeader>
              <CardContent className="grid grid-cols-1 md:grid-cols-3 gap-4">
                {taskEarningActivities.map((activity) => (
                  <div key={activity.activity} className="text-center p-4 border rounded-lg">
                    <activity.icon className="h-8 w-8 mx-auto mb-2 text-sheraton-gold" />
                    <h3 className="font-medium mb-1">{activity.activity}</h3>
                    <p className="text-sm text-muted-foreground">{activity.points}</p>
                  </div>
                ))}
                <p className="md:col-span-3 text-sm text-muted-foreground">
                  Eligible purchase points exclude taxes, tips, and fees. Referral rewards require a verified first purchase of at least UGX {(rewardsSummary?.policy.guestReferralMinimumUgx ?? 100000).toLocaleString()} for guests, or a first approved task/listing for service partners. Points currently do not expire; redemption is disabled until merchant settlement is available.
                </p>
              </CardContent>
            </Card>}
          </TabsContent>

          {/* Referrals Tab */}
          <TabsContent value="referrals" className="space-y-6">
            {userRole === 'manager' ? (
              // Manager Referrals
              <>
                <Card>
                  <CardHeader>
                    <CardTitle className="flex items-center gap-2">
                      <Users className="h-5 w-5 text-sheraton-gold" />
                      Refer Service Providers & Property Managers
                    </CardTitle>
                  </CardHeader>
                  <CardContent className="space-y-6">
                    <div className="text-center p-6 bg-sheraton-gold/10 rounded-lg">
                      <Gift className="h-12 w-12 mx-auto mb-4 text-sheraton-gold" />
                      <h3 className="text-xl font-bold mb-2">Grow Your Network</h3>
                      <p className="text-muted-foreground mb-4">
                        Refer qualified service providers or property managers to earn rewards and build your trusted network
                      </p>
                      <div className="flex items-center justify-center gap-2 p-3 bg-white rounded-lg border">
                        <code className="font-mono text-lg">
                          {generateServiceCode()}
                        </code>
                        <Button size="sm" onClick={copyServiceCode} disabled={!rewardsSummary?.referralCode}>
                          <Copy className="h-4 w-4" />
                        </Button>
                      </div>
                      <Button className="mt-4 sheraton-gradient text-white" onClick={shareReferralLink} disabled={!rewardsSummary?.referralCode}>
                        <Share2 className="h-4 w-4 mr-2" />
                        Share Referral Link
                      </Button>
                    </div>

                    <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                      <Card className="border-2 border-sheraton-gold/30">
                        <CardHeader className="pb-3">
                          <CardTitle className="text-base flex items-center gap-2">
                            <Users className="h-4 w-4 text-sheraton-gold" />
                            Refer Service Providers
                          </CardTitle>
                        </CardHeader>
                        <CardContent className="space-y-3">
                          <div>
                            <div className="text-2xl font-bold text-sheraton-gold">
                              {rewardsSummary?.policy.referrerBonusPoints ?? 250} points
                            </div>
                            <p className="text-xs text-muted-foreground mt-1">
                              After the referred provider completes a manager-approved task
                            </p>
                          </div>
                          <ul className="space-y-2 text-sm">
                            <li className="flex items-start gap-2">
                              <CheckCircle className="h-4 w-4 text-green-500 flex-shrink-0 mt-0.5" />
                              <span>Platform-funded promotional points</span>
                            </li>
                            <li className="flex items-start gap-2">
                              <CheckCircle className="h-4 w-4 text-green-500 flex-shrink-0 mt-0.5" />
                              <span>Both accounts are credited after qualification</span>
                            </li>
                          </ul>
                        </CardContent>
                      </Card>

                      <Card className="border-2 border-sheraton-gold/30">
                        <CardHeader className="pb-3">
                          <CardTitle className="text-base flex items-center gap-2">
                            <Briefcase className="h-4 w-4 text-sheraton-gold" />
                            Refer Managers
                          </CardTitle>
                        </CardHeader>
                        <CardContent className="space-y-3">
                          <div>
                            <div className="text-2xl font-bold text-sheraton-gold">
                              {rewardsSummary?.policy.referrerBonusPoints ?? 250} points
                            </div>
                            <p className="text-xs text-muted-foreground mt-1">
                              After the referred manager publishes their first hotel room
                            </p>
                          </div>
                          <ul className="space-y-2 text-sm">
                            <li className="flex items-start gap-2">
                              <CheckCircle className="h-4 w-4 text-green-500 flex-shrink-0 mt-0.5" />
                              <span>Points are separate from cash payments</span>
                            </li>
                            <li className="flex items-start gap-2">
                              <CheckCircle className="h-4 w-4 text-green-500 flex-shrink-0 mt-0.5" />
                              <span>Both the referrer and new manager earn points</span>
                            </li>
                          </ul>
                        </CardContent>
                      </Card>
                    </div>
                  </CardContent>
                </Card>

                <Card>
                  <CardHeader>
                    <CardTitle className="flex items-center gap-2">
                      <TrendingUp className="h-5 w-5 text-sheraton-gold" />
                      Your Referral Performance
                    </CardTitle>
                  </CardHeader>
                  <CardContent>
                    <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
                      <div className="text-center p-4 border rounded-lg">
                        <div className="text-2xl font-bold text-sheraton-gold">
                          {rewardsSummary?.referrals.total ?? 0}
                        </div>
                        <div className="text-sm text-muted-foreground">
                          Total Referred
                        </div>
                      </div>
                      <div className="text-center p-4 border rounded-lg">
                        <div className="text-2xl font-bold text-sheraton-gold">
                          {rewardsSummary?.referrals.qualified ?? 0}
                        </div>
                        <div className="text-sm text-muted-foreground">
                          Qualified Referrals
                        </div>
                      </div>
                      <div className="text-center p-4 border rounded-lg">
                        <div className="text-2xl font-bold text-sheraton-gold">
                          {(rewardsSummary?.referrals.pointsEarned ?? 0).toLocaleString()}
                        </div>
                        <div className="text-sm text-muted-foreground">
                          Referral Points Earned
                        </div>
                      </div>
                      <div className="text-center p-4 border rounded-lg">
                        <div className="text-2xl font-bold text-sheraton-gold">
                          {rewardsSummary?.referrals.total
                            ? `${Math.round((rewardsSummary.referrals.qualified / rewardsSummary.referrals.total) * 100)}%`
                            : "0%"}
                        </div>
                        <div className="text-sm text-muted-foreground">
                          Conversion Rate
                        </div>
                      </div>
                    </div>
                  </CardContent>
                </Card>
              </>
            ) : (
              // Service Provider Referrals
              <>
                <Card>
                  <CardHeader>
                    <CardTitle className="flex items-center gap-2">
                      <Users className="h-5 w-5 text-sheraton-gold" />
                      Refer Service Providers & Property Managers
                    </CardTitle>
                  </CardHeader>
                  <CardContent className="space-y-6">
                    <div className="text-center p-6 bg-sheraton-gold/10 rounded-lg">
                      <Gift className="h-12 w-12 mx-auto mb-4 text-sheraton-gold" />
                      <h3 className="text-xl font-bold mb-2">Grow Your Network & Earn</h3>
                      <p className="text-muted-foreground mb-4">
                        Refer qualified service providers or property managers and earn rewards
                      </p>
                      <div className="flex items-center justify-center gap-2 p-3 bg-white rounded-lg border">
                        <code className="font-mono text-lg">
                          {generateServiceCode()}
                        </code>
                        <Button size="sm" onClick={copyServiceCode}>
                          <Copy className="h-4 w-4" />
                        </Button>
                      </div>
                      <Button className="mt-4 sheraton-gradient text-white" onClick={shareReferralLink} disabled={!rewardsSummary?.referralCode}>
                        <Share2 className="h-4 w-4 mr-2" />
                        Share Referral Link
                      </Button>
                    </div>

                    <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                      <Card className="border-2 border-sheraton-gold/30">
                        <CardHeader className="pb-3">
                          <CardTitle className="text-base flex items-center gap-2">
                            <Users className="h-4 w-4 text-sheraton-gold" />
                            Refer Service Providers
                          </CardTitle>
                        </CardHeader>
                        <CardContent className="space-y-3">
                          <div>
                            <div className="text-2xl font-bold text-sheraton-gold">
                              {rewardsSummary?.policy.referrerBonusPoints ?? 250} Points
                            </div>
                            <p className="text-xs text-muted-foreground mt-1">
                              After the referred provider's first approved task
                            </p>
                          </div>
                          <ul className="space-y-2 text-sm">
                            <li className="flex items-start gap-2">
                              <CheckCircle className="h-4 w-4 text-green-500 flex-shrink-0 mt-0.5" />
                              <span>Bonus points to your account</span>
                            </li>
                            <li className="flex items-start gap-2">
                              <CheckCircle className="h-4 w-4 text-green-500 flex-shrink-0 mt-0.5" />
                              <span>Both accounts are credited after qualification</span>
                            </li>
                          </ul>
                        </CardContent>
                      </Card>

                      <Card className="border-2 border-sheraton-gold/30">
                        <CardHeader className="pb-3">
                          <CardTitle className="text-base flex items-center gap-2">
                            <Briefcase className="h-4 w-4 text-sheraton-gold" />
                            Refer Property Managers
                          </CardTitle>
                        </CardHeader>
                        <CardContent className="space-y-3">
                          <div>
                            <div className="text-2xl font-bold text-sheraton-gold">
                              {rewardsSummary?.policy.referrerBonusPoints ?? 250} Points
                            </div>
                            <p className="text-xs text-muted-foreground mt-1">
                              After the referred manager publishes their first hotel room
                            </p>
                          </div>
                          <ul className="space-y-2 text-sm">
                            <li className="flex items-start gap-2">
                              <CheckCircle className="h-4 w-4 text-green-500 flex-shrink-0 mt-0.5" />
                              <span>Platform-funded promotional points</span>
                            </li>
                            <li className="flex items-start gap-2">
                              <CheckCircle className="h-4 w-4 text-green-500 flex-shrink-0 mt-0.5" />
                              <span>Unlock special privileges</span>
                            </li>
                          </ul>
                        </CardContent>
                      </Card>
                    </div>
                  </CardContent>
                </Card>

                <Card>
                  <CardHeader>
                    <CardTitle className="flex items-center gap-2">
                      <TrendingUp className="h-5 w-5 text-sheraton-gold" />
                      Your Referral Performance
                    </CardTitle>
                  </CardHeader>
                  <CardContent>
                    <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
                      <div className="text-center p-4 border rounded-lg">
                        <div className="text-2xl font-bold text-sheraton-gold">
                          {rewardsSummary?.referrals.total ?? 0}
                        </div>
                        <div className="text-sm text-muted-foreground">
                          Total Referred
                        </div>
                      </div>
                      <div className="text-center p-4 border rounded-lg">
                        <div className="text-2xl font-bold text-sheraton-gold">
                          {rewardsSummary?.referrals.qualified ?? 0}
                        </div>
                        <div className="text-sm text-muted-foreground">
                          Qualified Referrals
                        </div>
                      </div>
                      <div className="text-center p-4 border rounded-lg">
                        <div className="text-2xl font-bold text-sheraton-gold">
                          {(rewardsSummary?.referrals.pointsEarned ?? 0).toLocaleString()}
                        </div>
                        <div className="text-sm text-muted-foreground">
                          Referral Points Earned
                        </div>
                      </div>
                      <div className="text-center p-4 border rounded-lg">
                        <div className="text-2xl font-bold text-sheraton-gold">
                          {rewardsSummary?.referrals.total
                            ? `${Math.round((rewardsSummary.referrals.qualified / rewardsSummary.referrals.total) * 100)}%`
                            : "0%"}
                        </div>
                        <div className="text-sm text-muted-foreground">
                          Conversion Rate
                        </div>
                      </div>
                    </div>
                  </CardContent>
                </Card>
              </>
            )}
          </TabsContent>
        </Tabs>
      </div>
    </div>
  );
};

export default ServicesProfilePage;
